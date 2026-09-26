-- greet.lua: say hello to everyone on the list
local M = {}

function M.greet(names)
  local msg = "Hello, "
  for i = 1, #names do
    msg = msg .. names[i]
    if i < #names then
      msg = msg .. ", "
    end
  end
  return msg .. "!"
end

return M
