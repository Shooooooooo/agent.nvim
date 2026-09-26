-- Minimal test harness for headless Neovim (no plenary/busted dependency).
-- Globals: describe, it, pending, before_each, after_each, assert (extended), wait_for.
local H = { suites = {}, current = nil, failures = 0, passes = 0, skipped = 0 }

local function new_suite(name, parent)
  return { name = name, parent = parent, tests = {}, children = {}, before = {}, after = {} }
end

H.root = new_suite('', nil)
H.current = H.root

function _G.describe(name, fn)
  local s = new_suite(name, H.current)
  table.insert(H.current.children, s)
  local prev = H.current
  H.current = s
  fn()
  H.current = prev
end

function _G.it(name, fn)
  table.insert(H.current.children, { name = name, fn = fn, test = true })
end

function _G.pending(name)
  table.insert(H.current.children, { name = name, pending = true, test = true })
end

function _G.before_each(fn) table.insert(H.current.before, fn) end
function _G.after_each(fn) table.insert(H.current.after, fn) end

local A = {}
local function fail(msg, level) error(msg, (level or 1) + 2) end
function A.eq(expected, actual, msg)
  if expected ~= actual then
    fail(string.format('%sexpected %s, got %s', msg and (msg .. ': ') or '', vim.inspect(expected), vim.inspect(actual)))
  end
end
function A.same(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    fail(string.format('%sexpected %s\n     got %s', msg and (msg .. ': ') or '', vim.inspect(expected), vim.inspect(actual)))
  end
end
function A.truthy(v, msg) if not v then fail((msg or 'expected truthy') .. ', got ' .. vim.inspect(v)) end end
function A.falsy(v, msg) if v then fail((msg or 'expected falsy') .. ', got ' .. vim.inspect(v)) end end
function A.matches(pattern, s, msg)
  if type(s) ~= 'string' or not s:find(pattern) then
    fail(string.format('%sexpected %s to match %q', msg and (msg .. ': ') or '', vim.inspect(s), pattern))
  end
end
function A.error(fn, pattern)
  local ok, err = pcall(fn)
  if ok then fail('expected an error') end
  if pattern and not tostring(err):find(pattern) then
    fail(string.format('error %q does not match %q', tostring(err), pattern))
  end
  return err
end
setmetatable(A, { __call = function(_, v, msg, ...) if not v then fail(msg or 'assertion failed') end return v, msg, ... end })
_G.assert = A

---Wait (processing events) until cond() is truthy; error on timeout.
function _G.wait_for(cond, timeout_ms, msg)
  local ok = vim.wait(timeout_ms or 5000, cond, 10)
  if not ok then
    error('timeout waiting for ' .. (msg or 'condition'), 2)
  end
end

local function full_name(suite, test)
  local parts = { test }
  local s = suite
  while s and s.name ~= '' do
    table.insert(parts, 1, s.name)
    s = s.parent
  end
  return table.concat(parts, ' > ')
end

local function collect_hooks(suite, key)
  local chain = {}
  local s = suite
  while s do
    table.insert(chain, 1, s)
    s = s.parent
  end
  local out = {}
  for _, st in ipairs(chain) do
    for _, h in ipairs(st[key]) do table.insert(out, h) end
  end
  if key == 'after' then
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    return rev
  end
  return out
end

local function run_suite(suite)
  for _, child in ipairs(suite.children) do
    if child.test then
      local name = full_name(suite, child.name)
      if child.pending then
        H.skipped = H.skipped + 1
        io.stdout:write('ok - # SKIP ' .. name .. '\n')
      else
        local ok, err = true, nil
        for _, h in ipairs(collect_hooks(suite, 'before')) do
          ok, err = xpcall(h, debug.traceback)
          if not ok then break end
        end
        if ok then ok, err = xpcall(child.fn, debug.traceback) end
        for _, h in ipairs(collect_hooks(suite, 'after')) do
          local aok, aerr = xpcall(h, debug.traceback)
          if ok and not aok then ok, err = aok, aerr end
        end
        if ok then
          H.passes = H.passes + 1
          io.stdout:write('ok - ' .. name .. '\n')
        else
          H.failures = H.failures + 1
          io.stdout:write('not ok - ' .. name .. '\n')
          io.stdout:write('  ' .. tostring(err):gsub('\n', '\n  ') .. '\n')
        end
      end
    else
      run_suite(child)
    end
  end
end

function H.run()
  run_suite(H.root)
  io.stdout:write(string.format('# %d passed, %d failed, %d skipped\n', H.passes, H.failures, H.skipped))
  return H.failures
end

return H
