-- Static scan for repeated line structures. Results go to quickfix, never to stats.
local cost = require("vim_coach.cost")

local M = {}

local MIN_RUN = 3
local MIN_AFFIX = 4 -- shared prefix/suffix must be at least this long to count

--- Reduce a line to its shape: whitespace collapsed, numbers -> #, strings -> "".
---@param line string
---@return string
function M.normalize(line)
  local s = line:gsub("\"[^\"]*\"", '""'):gsub("'[^']*'", "''")
  s = s:gsub("%d+", "#"):gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end

local function common_prefix(a, b)
  local n = math.min(#a, #b)
  local i = 1
  while i <= n and a:byte(i) == b:byte(i) do
    i = i + 1
  end
  return i - 1
end

local function common_suffix(a, b)
  local la, lb = #a, #b
  local n = math.min(la, lb)
  local i = 0
  while i < n and a:byte(la - i) == b:byte(lb - i) do
    i = i + 1
  end
  return i
end

--- Find runs. Pure and O(lines). Returns {lnum, count, kind} entries.
---@param lines string[]
---@return {lnum:integer, count:integer, kind:"same"|"affix"}[]
function M.find_runs(lines)
  local out = {}
  local n = #lines
  local norm = {}
  for i = 1, n do
    norm[i] = M.normalize(lines[i])
  end

  -- Pass 1: identical shape.
  local covered = {}
  local i = 1
  while i <= n do
    local j = i
    if norm[i] ~= "" then
      while j < n and norm[j + 1] == norm[i] do
        j = j + 1
      end
    end
    if j - i + 1 >= MIN_RUN then
      out[#out + 1] = { lnum = i, count = j - i + 1, kind = "same" }
      for k = i, j do
        covered[k] = true
      end
    end
    i = j + 1
  end

  -- Pass 2: shared non-trivial prefix or suffix on trimmed lines.
  local trimmed = {}
  for k = 1, n do
    trimmed[k] = vim.trim(lines[k])
  end
  local function affix_pass(measure)
    local a = 1
    while a <= n do
      local b = a
      if not covered[a] and #trimmed[a] > 0 then
        local len
        while b < n and not covered[b + 1] and #trimmed[b + 1] > 0 do
          local l = measure(trimmed[b], trimmed[b + 1])
          if l < MIN_AFFIX then
            break
          end
          len = len and math.min(len, l) or l
          if len < MIN_AFFIX then
            break
          end
          b = b + 1
        end
      end
      if b - a + 1 >= MIN_RUN then
        out[#out + 1] = { lnum = a, count = b - a + 1, kind = "affix" }
        for k = a, b do
          covered[k] = true
        end
      end
      a = b + 1
    end
  end
  affix_pass(common_prefix)
  affix_pass(common_suffix)

  table.sort(out, function(x, y)
    return x.lnum < y.lnum
  end)
  return out
end

---@param buf integer?
function M.run(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines > cost.max_lines then
    vim.notify("vim-coach: buffer too large to scan", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, r in ipairs(M.find_runs(lines)) do
    items[#items + 1] = {
      bufnr = buf,
      lnum = r.lnum,
      end_lnum = r.lnum + r.count - 1,
      text = ("%d similar lines: visual-block or :normal could edit them at once"):format(r.count),
    }
  end
  if #items == 0 then
    vim.notify("vim-coach: no repeated structures found")
    return
  end
  vim.fn.setqflist({}, " ", { title = "vim-coach scan", items = items })
  vim.cmd("copen")
end

return M
