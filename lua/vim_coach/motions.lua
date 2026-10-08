-- Pure helpers for the key-pattern detector: run classification and candidate
-- generation. Nothing here touches the editor, so it is easy to unit test.
local cost = require("vim_coach.cost")

local M = {}

-- Run kinds, in the order of cost.min_run keys.
M.KINDS = { "vertical", "horizontal", "word", "arrows" }

-- Count-less command token -> run kind index (1 vertical, 2 horizontal, 3 word, 4 arrows).
M.RUN = {
  j = 1, k = 1,
  h = 2, l = 2,
  w = 3, b = 3, e = 3, W = 3, B = 3, E = 3,
  ["<Up>"] = 4, ["<Down>"] = 4, ["<Left>"] = 4, ["<Right>"] = 4,
}

-- Arrow token -> equivalent hjkl motion.
M.ARROW = { ["<Up>"] = "k", ["<Down>"] = "j", ["<Left>"] = "h", ["<Right>"] = "l" }

--- Threshold (identical presses) for a run kind index.
---@param kind integer
---@return integer
function M.min_run(kind)
  return cost.min_run[M.KINDS[kind]]
end

--- hjkl/wbe base motion for a run token (arrows are mapped to hjkl).
---@param tok string
---@return string
function M.base(tok)
  return M.ARROW[tok] or tok
end

--- The (possibly multibyte) character starting at byte `col` (0-based).
---@param line string
---@param col integer
---@return string
function M.char_at(line, col)
  local b = line:byte(col + 1)
  if not b then
    return ""
  end
  local n = 1
  if b >= 240 then
    n = 4
  elseif b >= 224 then
    n = 3
  elseif b >= 192 then
    n = 2
  end
  return line:sub(col + 1, col + n)
end

--- Start byte (0-based) of the character that ends right before byte `col`.
local function prev_start(line, col)
  local p = col - 1
  while p > 0 do
    local b = line:byte(p + 1)
    if b < 128 or b >= 192 then
      break
    end
    p = p - 1
  end
  return p
end

-- Count start positions p in [lo, hi] (0-based) where `ch` occurs.
local function count_occ(line, ch, lo, hi)
  local n = 0
  local init = math.max(lo, 0) + 1
  while true do
    local s = line:find(ch, init, true)
    if not s or s - 1 > hi then
      break
    end
    n = n + 1
    init = s + 1
  end
  return n
end

-- Character class of byte b (1-based index into line): 0 blank, 1 word, 2 punctuation.
local function class(line, i, big)
  local b = line:byte(i)
  if b == 32 or b == 9 then
    return 0
  end
  if big or b >= 128 or b == 95 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
    return 1
  end
  return 2
end

--- One step of w/e/b (or W/E/B) inside a single line. nil when it would leave the line.
---@param line string
---@param col integer  0-based byte col
---@param motion string
---@return integer?
function M.step(line, col, motion)
  local len = #line
  local big = motion == "W" or motion == "E" or motion == "B"
  local m = motion:lower()
  local i = col + 1
  if m == "w" then
    local c = class(line, i, big)
    if c ~= 0 then
      while i <= len and class(line, i, big) == c do
        i = i + 1
      end
    end
    while i <= len and class(line, i, big) == 0 do
      i = i + 1
    end
    if i > len then
      return nil
    end
    return i - 1
  elseif m == "e" then
    i = i + 1
    while i <= len and class(line, i, big) == 0 do
      i = i + 1
    end
    if i > len then
      return nil
    end
    local c = class(line, i, big)
    while i + 1 <= len and class(line, i + 1, big) == c do
      i = i + 1
    end
    return i - 1
  elseif m == "b" then
    i = i - 1
    while i >= 1 and class(line, i, big) == 0 do
      i = i - 1
    end
    if i < 1 then
      return nil
    end
    local c = class(line, i, big)
    while i > 1 and class(line, i - 1, big) == c do
      i = i - 1
    end
    return i - 1
  end
  return nil
end

--- Smallest count (<= cap) of `motion` that moves from `from` to `to` in one line.
---@return integer?
function M.word_count(line, from, to, motion, cap)
  local pos = from
  for n = 1, cap or 8 do
    pos = M.step(line, pos, motion)
    if not pos then
      return nil
    end
    if pos == to then
      return n
    end
  end
  return nil
end

local function key(count, k)
  if count > 1 then
    return count .. k
  end
  return k
end

local function cand(idiom, keys, label, n)
  return { idiom = idiom, label = label or keys, keys = keys, cost = n or #keys }
end

local function vertical(base, n, from, to, ctx, out)
  local fwd = base == "j"
  -- Counting lines is only practical with relative line numbers on screen.
  if ctx.relnum ~= false then
    out[#out + 1] = cand("count-jk", key(n, base), nil)
  end
  out[#out + 1] = cand("paragraph-jump", fwd and "}" or "{")
  for _, k in ipairs({ "H", "M", "L" }) do
    out[#out + 1] = cand("screen-jump", k)
  end
  if to[1] == 1 then
    out[#out + 1] = cand("goto-line", "gg")
  elseif ctx.nlines and to[1] == ctx.nlines then
    out[#out + 1] = cand("goto-line", "G")
  end
  out[#out + 1] = cand("goto-line", to[1] .. "G")
  local half = fwd and "<C-d>" or "<C-u>"
  out[#out + 1] = cand("half-page", vim.keycode(half), half, 1)
  out[#out + 1] = cand("paragraph-jump", "2" .. (fwd and "}" or "{"))
end

-- f/t/F/T candidates for a same-row move.
local function find_char(line, from, to, out)
  if to[2] > from[2] then
    local ch = M.char_at(line, to[2])
    if ch ~= "" then
      local k = count_occ(line, ch, from[2] + 1, to[2])
      out[#out + 1] = cand("find-char", key(k, "f") .. ch)
    end
    local q = to[2] + #ch
    local tc = M.char_at(line, q)
    if tc ~= "" then
      local k = count_occ(line, tc, from[2] + 1, q)
      out[#out + 1] = cand("find-char", key(k, "t") .. tc)
    end
  elseif to[2] < from[2] then
    local ch = M.char_at(line, to[2])
    if ch ~= "" then
      local k = count_occ(line, ch, to[2], from[2] - 1)
      out[#out + 1] = cand("find-char", key(k, "F") .. ch)
    end
    if to[2] > 0 then
      local q = prev_start(line, to[2])
      local tc = M.char_at(line, q)
      local k = count_occ(line, tc, q, from[2] - 1)
      out[#out + 1] = cand("find-char", key(k, "T") .. tc)
    end
  end
end

local function line_ends(line, to, out)
  if line == "" then
    return
  end
  local last = #line - #M.char_at(line, prev_start(line, #line))
  if to[2] == last then
    out[#out + 1] = cand("line-ends", "$")
  end
  if to[2] == 0 then
    out[#out + 1] = cand("line-ends", "0")
  end
  local nb = line:find("%S")
  if nb and to[2] == nb - 1 and nb > 1 then
    out[#out + 1] = cand("line-ends", "^")
  end
end

--- Candidate shorter ways to make the same move. Unverified: the caller replays them.
---@param base string  j k h l w b e W B E
---@param n integer  presses in the run
---@param from {[1]:integer,[2]:integer}  (row, byte col) at run start
---@param to {[1]:integer,[2]:integer}  (row, byte col) at run end
---@param ctx {line:string?, nlines:integer?, relnum:boolean?}  line = text of row `to[1]`;
---  relnum = false drops counted j/k (no relative line numbers to read the count from)
---@return VimCoach.Candidate[]
function M.candidates(base, n, from, to, ctx)
  local out = {}
  local line = ctx.line or ""
  if base == "j" or base == "k" then
    vertical(base, n, from, to, ctx, out)
  elseif base == "h" or base == "l" then
    if from[1] == to[1] then
      find_char(line, from, to, out)
      line_ends(line, to, out)
      local fwd = base == "l"
      for _, m in ipairs(fwd and { "w", "e", "W", "E" } or { "b", "B" }) do
        local c = M.word_count(line, from[2], to[2], m)
        if c then
          out[#out + 1] = cand("word-motion", key(c, m))
        end
      end
    end
  else
    out[#out + 1] = cand("word-motion", key(n, base))
    if from[1] == to[1] then
      find_char(line, from, to, out)
    end
    line_ends(line, to, out)
  end
  return out
end

return M
