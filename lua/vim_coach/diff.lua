-- Pure functions: diff a before/after text region and classify the edit shape.
-- Nothing here touches buffers or global state.
local M = {}

---@class VimCoach.Item
---@field row integer     1-based row in `before`
---@field lb string       line before
---@field la string       line after
---@field pre integer     common prefix bytes
---@field suf integer     common suffix bytes
---@field old string      text removed (lb between prefix and suffix)
---@field new string      text inserted (la between prefix and suffix)

---@class VimCoach.Shape
---@field kind "none"|"intra"|"per_line"|"del_lines"|"add_lines"|"dup"|"move"|"join"|"other"
---@field hunks table[]
---@field items VimCoach.Item[]?   changed line pairs (intra and per_line)
---@field group table?             facts shared by all items (see M.group)
---@field row integer?             del_lines/add_lines/join/dup: first row
---@field n integer?               number of lines involved
---@field lines string[]?          del_lines/add_lines/dup: the lines
---@field where "below"|"above"?   dup: copy sits below or above its source
---@field from integer?            move: first row of the moved block (before)
---@field dest integer?            move: row after which the block lands (before, 0 = top)
---@field scale integer            lines or items affected

local function diff_fn()
  return (vim.text and vim.text.diff) or vim.diff
end

--- Line hunks between two line lists.
---@param before string[]
---@param after string[]
---@return {a:integer, na:integer, b:integer, nb:integer}[]
function M.hunks(before, after)
  local a = #before > 0 and (table.concat(before, "\n") .. "\n") or ""
  local b = #after > 0 and (table.concat(after, "\n") .. "\n") or ""
  local ok, res = pcall(diff_fn(), a, b, { result_type = "indices" })
  local out = {}
  if not ok or type(res) ~= "table" then
    return out
  end
  for i, h in ipairs(res) do
    out[i] = { a = h[1], na = h[2], b = h[3], nb = h[4] }
  end
  return out
end

--- Common prefix and suffix lengths in bytes (never splitting a UTF-8 character).
---@param a string
---@param b string
---@return integer pre, integer suf
function M.affix(a, b)
  local la, lb = #a, #b
  local max = math.min(la, lb)
  local pre = 0
  while pre < max and a:byte(pre + 1) == b:byte(pre + 1) do
    pre = pre + 1
  end
  -- Back off to a character boundary.
  while pre > 0 do
    local c1, c2 = a:byte(pre + 1), b:byte(pre + 1)
    if (c1 and c1 >= 0x80 and c1 < 0xC0) or (c2 and c2 >= 0x80 and c2 < 0xC0) then
      pre = pre - 1
    else
      break
    end
  end
  local suf = 0
  local smax = max - pre
  while suf < smax and a:byte(la - suf) == b:byte(lb - suf) do
    suf = suf + 1
  end
  while suf > 0 do
    local c1, c2 = a:byte(la - suf + 1), b:byte(lb - suf + 1)
    if (c1 and c1 >= 0x80 and c1 < 0xC0) or (c2 and c2 >= 0x80 and c2 < 0xC0) then
      suf = suf - 1
    else
      break
    end
  end
  return pre, suf
end

---@return VimCoach.Item
function M.item(row, lb, la)
  local pre, suf = M.affix(lb, la)
  return {
    row = row,
    lb = lb,
    la = la,
    pre = pre,
    suf = suf,
    old = lb:sub(pre + 1, #lb - suf),
    new = la:sub(pre + 1, #la - suf),
  }
end

-- Position tags for an item: where in the line the change sits.
local function tags(it)
  local t = {}
  if it.pre == 0 then
    t.bol = true
  end
  if it.suf == 0 then
    t.eol = true
  end
  if it.lb:sub(1, it.pre):match("^%s*$") and it.pre == #it.lb:match("^%s*") then
    t.indent = true
  end
  return t
end

--- Facts shared by a group of changed lines.
---@param items VimCoach.Item[]
function M.group(items)
  local g = {
    n = #items,
    first = items[1].row,
    last = items[#items].row,
    insert = true,
    delete = true,
    same_new = true,
    same_old = true,
    case_only = true,
    indent = true,
    pos = { bol = true, eol = true, indent = true, col = true },
  }
  g.contiguous = (g.last - g.first + 1) == g.n
  local f = items[1]
  for _, it in ipairs(items) do
    if it.old ~= "" then
      g.insert = false
    end
    if it.new ~= "" then
      g.delete = false
    end
    if it.new ~= f.new then
      g.same_new = false
    end
    if it.old ~= f.old then
      g.same_old = false
    end
    if it.old:lower() ~= it.new:lower() or it.old == it.new then
      g.case_only = false
    end
    local wo, wn = it.lb:match("^%s*"), it.la:match("^%s*")
    if wo == wn or it.lb:sub(#wo + 1) ~= it.la:sub(#wn + 1) then
      g.indent = false
    end
    local t = tags(it)
    for k in pairs({ bol = 1, eol = 1, indent = 1 }) do
      if not t[k] then
        g.pos[k] = nil
      end
    end
    if it.pre ~= f.pre then
      g.pos.col = nil
    end
  end
  return g
end

local function multiset(lines)
  local m = {}
  for _, l in ipairs(lines) do
    m[l] = (m[l] or 0) + 1
  end
  return m
end

local function same_multiset(a, b)
  if #a ~= #b then
    return false
  end
  local ma, mb = multiset(a), multiset(b)
  for k, v in pairs(ma) do
    if mb[k] ~= v then
      return false
    end
  end
  return true
end

local function slice(t, s, n)
  local out = {}
  for i = s, s + n - 1 do
    out[#out + 1] = t[i]
  end
  return out
end

local function equal_slice(a, sa, b, sb, n)
  if sa < 1 or sb < 1 or sa + n - 1 > #a or sb + n - 1 > #b then
    return false
  end
  for i = 0, n - 1 do
    if a[sa + i] ~= b[sb + i] then
      return false
    end
  end
  return true
end

--- Classify the edit between two line lists.
---@param before string[]
---@param after string[]
---@return VimCoach.Shape
function M.classify(before, after)
  local hunks = M.hunks(before, after)
  local shape = { kind = "other", hunks = hunks, scale = 1 }
  if #hunks == 0 then
    shape.kind = "none"
    return shape
  end

  local paired = true
  for _, h in ipairs(hunks) do
    if h.na ~= h.nb or h.na == 0 then
      paired = false
      break
    end
  end

  if paired then
    local items = {}
    for _, h in ipairs(hunks) do
      for i = 0, h.na - 1 do
        items[#items + 1] = M.item(h.a + i, before[h.a + i], after[h.b + i])
      end
    end
    shape.items = items
    shape.group = M.group(items)
    shape.kind = #items == 1 and "intra" or "per_line"
    shape.scale = #items == 1 and math.max(1, vim.fn.strchars(items[1].old)) or #items
    return shape
  end

  if #hunks == 1 then
    local h = hunks[1]
    if h.nb == 0 then
      shape.kind = "del_lines"
      shape.row, shape.n = h.a, h.na
      shape.lines = slice(before, h.a, h.na)
      shape.scale = h.na
    elseif h.na == 0 then
      shape.row, shape.n = h.a, h.nb -- h.a = row after which lines were added
      shape.lines = slice(after, h.b, h.nb)
      shape.scale = h.nb
      shape.kind = "add_lines"
      if equal_slice(before, h.a - h.nb + 1, after, h.b, h.nb) then
        shape.kind, shape.where, shape.row = "dup", "below", h.a - h.nb + 1
      elseif equal_slice(before, h.a + 1, after, h.b, h.nb) then
        shape.kind, shape.where, shape.row = "dup", "above", h.a + 1
      end
    elseif h.nb == 1 and h.na >= 2 then
      shape.kind = "join"
      shape.row, shape.n = h.a, h.na
      shape.scale = h.na
    end
    return shape
  end

  if #hunks == 2 then
    local d, a = hunks[1], hunks[2]
    if d.nb ~= 0 then
      d, a = a, d
    end
    if d.nb == 0 and a.na == 0 and d.na == a.nb
      and same_multiset(slice(before, d.a, d.na), slice(after, a.b, a.nb)) then
      shape.kind = "move"
      shape.from, shape.n = d.a, d.na
      shape.lines = slice(before, d.a, d.na)
      local lead = a.b - 1
      shape.dest = lead < d.a and lead or (lead + d.na)
      shape.scale = d.na
    end
  end
  return shape
end

--- A key for "same edit shape" detection. Held in memory only, never persisted.
---@param shape VimCoach.Shape
---@return string?
function M.signature(shape)
  if shape.kind == "intra" then
    local it = shape.items[1]
    return table.concat({ "i", it.new, it.old == "" and "0" or "1" }, "|")
  elseif shape.kind == "per_line" then
    local g = shape.group
    return table.concat({ "p", g.same_new and shape.items[1].new or "", g.insert and "0" or "1" }, "|")
  elseif shape.kind == "del_lines" or shape.kind == "dup" or shape.kind == "move" or shape.kind == "join" then
    return shape.kind .. "|" .. tostring(shape.n)
  end
  return nil
end

return M
