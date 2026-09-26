---@mod agent.crypto.sha1 Pure-Lua SHA-1 (FIPS 180-4) on the LuaJIT `bit` module
---
--- Neovim has no built-in SHA-1 (only sha256()), and the WebSocket handshake needs one for
--- Sec-WebSocket-Accept. Safe to call from fast (libuv) contexts.
local bit = require('bit')

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit
local byte, char, format = string.byte, string.char, string.format

local M = {}

local function be32(n)
  return char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

-- Scratch message schedule, reused across blocks (the module is not re-entrant across coroutines
-- mid-block, but a block is processed without yielding).
local w = {}

---Process one 64-byte block of `s` starting at byte offset `p` (1-based).
local function block(s, p, h0, h1, h2, h3, h4)
  for i = 0, 15 do
    local a, b, c, d = byte(s, p, p + 3)
    w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    p = p + 4
  end
  for i = 16, 79 do
    w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
  end
  local a, b, c, d, e = h0, h1, h2, h3, h4
  for i = 0, 19 do
    local t = tobit(rol(a, 5) + bor(band(b, c), band(bnot(b), d)) + e + 0x5A827999 + w[i])
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end
  for i = 20, 39 do
    local t = tobit(rol(a, 5) + bxor(b, c, d) + e + 0x6ED9EBA1 + w[i])
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end
  for i = 40, 59 do
    local t = tobit(rol(a, 5) + bor(band(b, c), band(b, d), band(c, d)) + e + 0x8F1BBCDC + w[i])
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end
  for i = 60, 79 do
    local t = tobit(rol(a, 5) + bxor(b, c, d) + e + 0xCA62C1D6 + w[i])
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end
  return tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
end

---SHA-1 of `msg`.
---@param msg string arbitrary bytes
---@return string digest raw 20-byte digest
function M.digest(msg)
  assert(type(msg) == 'string', 'sha1: string expected')
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local len = #msg
  -- Full blocks straight from the input (no copy of large messages).
  local full = len - len % 64
  for p = 1, full, 64 do
    h0, h1, h2, h3, h4 = block(msg, p, h0, h1, h2, h3, h4)
  end
  -- Padding: 0x80, zeros to 56 mod 64, then the 64-bit big-endian bit length.
  local bits = len * 8
  local hi = math.floor(bits / 4294967296)
  local lo = bits - hi * 4294967296
  local tail = msg:sub(full + 1) .. '\128' .. string.rep('\0', (55 - len) % 64) .. be32(hi) .. be32(lo)
  for p = 1, #tail, 64 do
    h0, h1, h2, h3, h4 = block(tail, p, h0, h1, h2, h3, h4)
  end
  return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3) .. be32(h4)
end

---SHA-1 of `msg` as 40 lowercase hex characters.
---@param msg string
---@return string
function M.hex(msg)
  return (M.digest(msg):gsub('.', function(c)
    return format('%02x', byte(c))
  end))
end

setmetatable(M, {
  ---`require('agent.crypto.sha1')(msg)` is `digest(msg)`.
  __call = function(_, msg)
    return M.digest(msg)
  end,
})

return M
