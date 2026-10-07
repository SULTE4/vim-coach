-- Pure functions: edit shape -> replayable candidate idioms, cheapest first.
--
-- Candidate cost counts keystrokes the idiom needs, not the text the user types either
-- way (the inserted text, <Esc>). Text the candidate must type beyond what the user
-- typed is added to the cost. verify.texts() decides which candidates are real.
local cost = require("vim_coach.cost")

local M = {}

local WORD = "[%w_\128-\255]"
local K = {
  cw = vim.keycode("<C-w>"),
  cu = vim.keycode("<C-u>"),
  cv = vim.keycode("<C-v>"),
  esc = vim.keycode("<Esc>"),
}

local function chars(s)
  return vim.fn.strchars(s)
end

local function digits(n)
  return #tostring(n)
end

-- Tie-break between equally cheap candidates: lower is preferred.
local RANK = { ["dt-char"] = 4, ["count-x"] = 4, ["substitute-char"] = 5, ["case-change"] = 4 }

local function before(a, b)
  if a.cost ~= b.cost then
    return a.cost < b.cost
  end
  local ra, rb = RANK[a.idiom] or 3, RANK[b.idiom] or 3
  if ra ~= rb then
    return ra < rb
  end
  return a.seq < b.seq
end

-- Context --------------------------------------------------------------------

local function make_ctx(span, shape)
  local cur = span.cursor_before or { 1, 0 }
  return {
    span = span,
    shape = shape,
    row = cur[1] - (span.first_row or 1) + 1,
    col = cur[2],
    kd = span.keys,
    out = {},
    n = 0,
  }
end

-- Cursor is already on `row`, columns lo..hi: no repositioning needed.
local function at_col(ctx, row, lo, hi)
  if ctx.row == row and ctx.col >= lo and ctx.col <= (hi or lo) then
    return nil, 0
  end
  return { row, lo }, cost.reposition
end

-- Cursor is anywhere on rows rlo..rhi.
local function at_rows(ctx, rlo, rhi)
  if ctx.row >= rlo and ctx.row <= rhi then
    return nil, 0
  end
  return { rlo, 0 }, cost.reposition
end

local function add(ctx, c, cursor, extra)
  c.cursor = cursor
  c.cost = c.cost + (extra or 0)
  ctx.n = ctx.n + 1
  c.seq = ctx.n
  ctx.out[#ctx.out + 1] = c
end

local function key(ctx, idiom, label, keys, base, cursor, extra)
  add(ctx, { idiom = idiom, label = label, keys = keys, cost = base }, cursor, extra)
end

-- Commands that are mappings (gc) do not work under `normal!`, so replay via :normal.
local function mapped(ctx, idiom, keys, base, cursor, extra)
  add(ctx, { idiom = idiom, label = keys, ex = "normal " .. keys, cost = base }, cursor, extra)
end

-- Keys needed to select n lines with V.
local function rsel(n)
  if n <= 1 then
    return 0
  end
  return 1 + digits(n - 1) + 1
end

-- Ex candidate. `body` is the command without range; `typed` is user text inside it.
local function ex(ctx, idiom, n, rng, body, typed, cursor, extra, label_body)
  local label = ":" .. (n > 1 and "'<,'>" or "") .. (label_body or body)
  local c = rsel(n) + 2 + chars(label_body or body) - chars(typed or "")
  add(ctx, { idiom = idiom, label = label, ex = rng .. body, cost = c }, cursor, extra)
end

local function esc_pat(s)
  return (vim.fn.escape(s, [[\/.*$^~[]]))
end

local function esc_repl(s)
  return (vim.fn.escape(s, [[\/&~]]))
end

local function is_word_at(s, i)
  return i >= 1 and i <= #s and s:sub(i, i):match(WORD) ~= nil
end

-- Single-line edits ----------------------------------------------------------

local function rfind(s, ch, upto)
  for i = upto, 1, -1 do
    if s:sub(i, i) == ch then
      return i
    end
  end
end

local function find_open(s, from, open, close)
  local depth = 0
  for i = from, 1, -1 do
    local c = s:sub(i, i)
    if c == close then
      depth = depth + 1
    elseif c == open then
      if depth == 0 then
        return i
      end
      depth = depth - 1
    end
  end
end

local function find_close(s, from, open, close)
  local depth = 0
  for i = from, #s do
    local c = s:sub(i, i)
    if c == open then
      depth = depth + 1
    elseif c == close then
      if depth == 0 then
        return i
      end
      depth = depth - 1
    end
  end
end

local function find_tag(s, a, b)
  local found_s, found_e
  local init = 1
  while true do
    local _, e1, name = s:find("<([%w_:%-%.]+)[^<>]*>", init)
    if not e1 then
      break
    end
    local ca = s:find("</" .. (name:gsub("%p", "%%%0")) .. ">", e1 + 1)
    if ca and e1 + 1 <= a and ca - 1 >= b then
      found_s, found_e = e1 + 1, ca - 1
    end
    init = e1 + 1
  end
  return found_s, found_e
end

-- Text objects around the changed region: ci" ci( cit and the d forms.
local function delimiters(ctx, it)
  local lb, la, pre, old = it.lb, it.la, it.pre, it.old
  local e = pre + #old
  local function emit(idiom, open, o, c)
    local nc = la:sub(o + 1, #la - (#lb - c + 1))
    local verb = nc == "" and "d" or "c"
    local extra = nc == "" and 0 or math.max(0, chars(nc) - chars(it.new))
    local label = verb .. "i" .. open
    -- Quotes are searched forward on the line, so any column before the closing one works.
    local cur, rp = at_col(ctx, it.row, open:match("[\"'`]") and 0 or o - 1, c - 1)
    key(ctx, idiom, label, label .. nc, 3, cur, extra + rp)
  end
  for _, q in ipairs({ '"', "'", "`" }) do
    local o = rfind(lb, q, pre)
    local c = o and lb:find(q, e + 1, true)
    if o and c then
      emit("ci-quote", q, o, c)
    end
  end
  for _, pair in ipairs({ { "(", ")" }, { "[", "]" }, { "{", "}" }, { "<", ">" } }) do
    local o = find_open(lb, pre, pair[1], pair[2])
    local c = o and find_close(lb, e + 1, pair[1], pair[2])
    if o and c then
      emit("ci-bracket", pair[1], o, c)
    end
  end
  local ts, te = find_tag(lb, pre + 1, e)
  if ts then
    local nc = la:sub(ts, #la - (#lb - te))
    local verb = nc == "" and "d" or "c"
    local extra = nc == "" and 0 or math.max(0, chars(nc) - chars(it.new))
    local label = verb .. "it"
    local cur, rp = at_col(ctx, it.row, ts - 1, te - 1)
    key(ctx, "ci-tag", label, label .. nc, 3, cur, extra + rp)
  end
end

local function words(ctx, it)
  local lb, la, pre, old, new = it.lb, it.la, it.pre, it.old, it.new
  if new ~= "" then
    if not old:match("^" .. WORD .. "+$") then
      return
    end
    local ws, we = pre + 1, pre + #old
    while is_word_at(lb, ws - 1) do
      ws = ws - 1
    end
    while is_word_at(lb, we + 1) do
      we = we + 1
    end
    local nw = la:sub(ws, #la - (#lb - we))
    local extra = math.max(0, chars(nw) - chars(new))
    local cur, rp = at_col(ctx, it.row, ws - 1, we - 1)
    key(ctx, "ciw", "ciw", "ciw" .. nw, 3, cur, extra + rp)
    local cur2, rp2 = at_col(ctx, it.row, ws - 1)
    key(ctx, "ciw", "cw", "cw" .. nw, 2, cur2, extra + rp2)
    return
  end
  local lead, trail = #old:match("^%s*"), #old:match("%s*$")
  local cs, ce = pre + 1 + lead, pre + #old - trail
  if cs > ce then
    return
  end
  local core = lb:sub(cs, ce)
  if not core:match("^" .. WORD .. "+$") or is_word_at(lb, cs - 1) or is_word_at(lb, ce + 1) then
    return
  end
  local cur, rp = at_col(ctx, it.row, cs - 1, ce - 1)
  key(ctx, "diw", "diw", "diw", 3, cur, rp)
  key(ctx, "diw", "daw", "daw", 3, cur, rp)
  local cur2, rp2 = at_col(ctx, it.row, cs - 1)
  key(ctx, "diw", "dw", "dw", 2, cur2, rp2)
  key(ctx, "diw", "de", "de", 2, cur2, rp2)
end

local function first_char(s)
  return vim.fn.strcharpart(s, 0, 1)
end

local function last_char(s)
  return vim.fn.strcharpart(s, chars(s) - 1, 1)
end

local function intra(ctx, it)
  local lb, la, pre, suf, old, new = it.lb, it.la, it.pre, it.suf, it.old, it.new
  local row = it.row
  local nold = chars(old)
  local op = new == "" and "d" or "c"

  if old == "" then
    -- Pure insertion: A / I.
    if suf == 0 then
      local cur, rp = at_rows(ctx, row, row)
      key(ctx, "append-eol", "A", "A" .. new, 1, cur, rp)
    end
    local ws = #lb:match("^%s*")
    if pre == ws then
      local cur, rp = at_rows(ctx, row, row)
      key(ctx, "insert-bol", "I", "I" .. new, 1, cur, rp)
    end
    return
  end

  delimiters(ctx, it)
  words(ctx, it)

  -- Tail of line.
  if suf == 0 then
    local cur, rp = at_col(ctx, row, pre)
    if new == "" then
      key(ctx, "delete-eol", "D", "D", 1, cur, rp)
    else
      key(ctx, "change-eol", "C", "C" .. new, 1, cur, rp)
    end
  end

  -- Up to a character.
  if nold >= 2 then
    local cur, rp = at_col(ctx, row, pre)
    if suf > 0 then
      local ch = first_char(lb:sub(pre + #old + 1))
      key(ctx, "dt-char", op .. "t" .. ch, op .. "t" .. ch .. new, 3, cur, rp)
    end
    local ch = last_char(old)
    key(ctx, "dt-char", op .. "f" .. ch, op .. "f" .. ch .. new, 3, cur, rp)
    if suf > 0 then
      local cur2, rp2 = at_col(ctx, row, pre + #old)
      if pre > 0 then
        local c1 = last_char(lb:sub(1, pre))
        key(ctx, "dt-char", op .. "T" .. c1, op .. "T" .. c1 .. new, 3, cur2, rp2)
      end
      local c2 = first_char(old)
      key(ctx, "dt-char", op .. "F" .. c2, op .. "F" .. c2 .. new, 3, cur2, rp2)
    end
  end

  -- Whole line replaced.
  if new ~= "" and (nold >= 3 or (pre == 0 and suf == 0)) then
    local cur, rp = at_col(ctx, row, 0, math.max(#lb - 1, 0))
    local ws = lb:match("^%s*")
    if ws ~= "" and la:sub(1, #ws) == ws then
      local text = la:sub(#ws + 1)
      key(ctx, "cc-line", "cc", "cc" .. text, 2, cur, rp + math.max(0, chars(text) - chars(new)))
    end
    key(ctx, "cc-line", "cc", "cc" .. la, 2, cur, rp + math.max(0, chars(la) - chars(new)))
  end

  -- Repeated x.
  if new == "" then
    local kd_ok = ctx.kd and ctx.kd.x >= cost.min_run_edit.x
    if nold >= cost.min_run_edit.x and kd_ok then
      local cur, rp = at_col(ctx, row, pre)
      key(ctx, "count-x", nold .. "x", nold .. "x", digits(nold) + 1, cur, rp)
    end
  else
    local cur, rp = at_col(ctx, row, pre)
    local lbl = (nold > 1 and nold or "") .. "s"
    key(ctx, "substitute-char", lbl, lbl .. new, digits(nold) + 1 - (nold == 1 and 1 or 0), cur, rp)
  end

  -- Case change.
  if old:lower() == new:lower() and old ~= new then
    local cur, rp = at_col(ctx, row, pre)
    local lbl = (nold > 1 and nold or "") .. "~"
    key(ctx, "case-change", lbl, lbl, digits(nold) + 1 - (nold == 1 and 1 or 0), cur, rp)
    local g = new == new:upper() and "gU" or (new == new:lower() and "gu" or "g~")
    if old:match("^" .. WORD .. "+$") and not is_word_at(lb, pre) and not is_word_at(lb, pre + #old + 1) then
      local c3, r3 = at_col(ctx, row, pre, pre + #old - 1)
      key(ctx, "case-change", g .. "iw", g .. "iw", 4, c3, r3)
      key(ctx, "case-change", g .. "w", g .. "w", 3, cur, rp)
      key(ctx, "case-change", g .. "e", g .. "e", 3, cur, rp)
    end
    if pre == 0 and suf == 0 then
      local c4, r4 = at_col(ctx, row, 0, math.max(#lb - 1, 0))
      local tail = g == "g~" and "~" or g:sub(2)
      key(ctx, "case-change", g .. tail, g .. tail, 3, c4, r4)
    end
    if suf == 0 then
      key(ctx, "case-change", g .. "$", g .. "$", 3, cur, rp)
    end
  end
end

-- Simulated <C-w> in insert mode: insertion point (bytes before cursor) after one press.
local function ctrl_w_pos(s, e)
  local i = e
  while i > 0 and s:sub(i, i):match("%s") do
    i = i - 1
  end
  if i == 0 then
    return 0
  end
  local isw = s:sub(i, i):match(WORD) ~= nil
  while i > 0 do
    local ch = s:sub(i, i)
    if ch:match("%s") or (ch:match(WORD) ~= nil) ~= isw then
      break
    end
    i = i - 1
  end
  return i
end

-- Many <BS> in insert mode: <C-w> and <C-u>.
local function backspaces(ctx, it)
  local lb, la, pre, suf, new = it.lb, it.la, it.pre, it.suf, it.new
  local e0 = #lb - suf
  if e0 < 1 then
    return
  end
  local enter, cur, rp
  if suf == 0 then
    enter = "A"
    cur, rp = at_rows(ctx, it.row, it.row)
  else
    enter = "i"
    cur, rp = at_col(ctx, it.row, e0)
  end
  local function tail(s0)
    return la:sub(s0 + 1, #la - suf)
  end
  local s = e0
  for m = 1, 3 do
    s = ctrl_w_pos(lb, s)
    if s <= pre then
      local t = tail(s)
      key(ctx, "insert-ctrl-w", "<C-w>", enter .. string.rep(K.cw, m) .. t, 1 + m, cur,
        rp + math.max(0, chars(t) - chars(new)))
    end
    if s == 0 then
      break
    end
  end
  local ws = #lb:match("^%s*")
  for _, s0 in ipairs(ws > 0 and { 0, ws } or { 0 }) do
    if s0 <= pre then
      local t = tail(s0)
      key(ctx, "insert-ctrl-u", "<C-u>", enter .. K.cu .. t, 2, cur, rp + math.max(0, chars(t) - chars(new)))
    end
  end
end

-- Groups of changed lines ----------------------------------------------------

local function range_of(ctx, g)
  local rows = ctx.shape.items
  if g.contiguous then
    local r = g.first == g.last and tostring(g.first) or (g.first .. "," .. g.last)
    return r, ""
  end
  -- Gaps allowed when every unchanged line in between is blank.
  local changed = {}
  for _, it in ipairs(rows) do
    changed[it.row] = true
  end
  for r = g.first, g.last do
    if not changed[r] and ctx.span.before[r] and ctx.span.before[r]:match("%S") then
      return nil
    end
  end
  return g.first .. "," .. g.last, "g/\\S/"
end

local function width(ws, ts)
  local w = 0
  for ch in ws:gmatch(".") do
    w = ch == "\t" and (w + ts - w % ts) or (w + 1)
  end
  return w
end

local function buf_opt(ctx, name, default)
  local b = ctx.span.buf
  if b and vim.api.nvim_buf_is_valid(b) then
    return vim.bo[b][name]
  end
  return default
end

local function indent_level(ctx, items)
  local ts = buf_opt(ctx, "tabstop", 8)
  local sw = buf_opt(ctx, "shiftwidth", 8)
  if sw == 0 then
    sw = ts
  end
  local k
  for _, it in ipairs(items) do
    local d = width(it.la:match("^%s*"), ts) - width(it.lb:match("^%s*"), ts)
    if d % sw ~= 0 or d == 0 then
      return nil
    end
    local v = math.floor(d / sw)
    if k and k ~= v then
      return nil
    end
    k = v
  end
  return k
end

local function group(ctx)
  local shape = ctx.shape
  local g, items = shape.group, shape.items
  local n, first, last = g.n, g.first, g.last
  local f = items[1]
  local rng, filter = range_of(ctx, g)

  -- Same text added on many lines.
  if n >= 2 and g.insert and g.same_new then
    local new = f.new
    local nr = last - first + 1
    local variants = {}
    if g.pos.bol then
      variants[#variants + 1] = { key = "I", pat = "^", norm = "0i", col = 0 }
    elseif g.pos.indent then
      variants[#variants + 1] = { key = "I", pat = [[^\s*\zs]], norm = "I", col = f.pre }
    end
    if g.pos.eol then
      variants[#variants + 1] = { key = "A", pat = "$", norm = "A", eol = true }
    end
    if g.pos.col and not g.pos.bol and not g.pos.eol and not g.pos.indent then
      variants[#variants + 1] = { key = "I", col = f.pre, block_only = true }
    end
    for _, v in ipairs(variants) do
      if g.contiguous then
        local lbl = "<C-v>" .. (n - 1) .. "j" .. (v.eol and "$" or "") .. v.key
        local c = 1 + digits(n - 1) + 1 + (v.eol and 1 or 0) + 1
        local cur, rp
        if v.eol then
          cur, rp = at_rows(ctx, first, first)
        elseif g.pos.col then
          cur, rp = at_col(ctx, first, v.col)
        end
        if v.eol or g.pos.col then
          key(ctx, "visual-block", lbl,
            K.cv .. (n - 1) .. "j" .. (v.eol and "$" or "") .. v.key .. new .. K.esc, c, cur, rp or 0)
        end
      end
      if rng and not v.block_only then
        local cur, rp = at_rows(ctx, first, first)
        ex(ctx, filter == "" and "normal-range" or "global-cmd", nr, rng,
          filter .. "norm! " .. v.norm .. new, new, cur, rp, filter .. "norm " .. v.norm .. new)
        local body = filter .. "s/" .. v.pat .. "/" .. esc_repl(new) .. "/"
        ex(ctx, filter == "" and "subst-range" or "global-cmd", nr, rng, body, new, cur, rp)
      end
    end
  end

  -- Same substitution on many lines.
  if n >= 2 and g.same_old and g.same_new and f.old ~= "" and rng then
    local nr = last - first + 1
    local cur, rp = at_rows(ctx, first, first)
    local pats = {}
    if g.pos.bol then
      pats[#pats + 1] = "^" .. esc_pat(f.old)
    end
    if g.pos.eol then
      pats[#pats + 1] = esc_pat(f.old) .. "$"
    end
    pats[#pats + 1] = esc_pat(f.old)
    local repl = esc_repl(f.new)
    for _, pat in ipairs(pats) do
      for _, flags in ipairs({ "", "g" }) do
        ex(ctx, "subst-range", nr, rng, filter .. "s/" .. pat .. "/" .. repl .. "/" .. flags, f.new, cur, rp)
      end
    end
    if not g.contiguous then
      ex(ctx, "global-cmd", nr, rng, "g/" .. esc_pat(f.old) .. "/s//" .. repl .. "/", f.new, cur, rp)
    end
  end

  -- Same text removed from many lines: visual block delete.
  if n >= 2 and g.delete and g.same_old and g.contiguous and g.pos.col then
    local k = chars(f.old)
    local cur, rp = at_col(ctx, first, f.pre)
    local lbl = "<C-v>" .. (n - 1) .. "j" .. (k > 1 and ((k - 1) .. "l") or "") .. "d"
    local c = 1 + digits(n - 1) + 1 + (k > 1 and digits(k - 1) + 1 or 0) + 1
    key(ctx, "visual-block", lbl,
      K.cv .. (n - 1) .. "j" .. (k > 1 and ((k - 1) .. "l") or "") .. "d", c, cur, rp)
  end

  -- Indent / dedent.
  if g.indent then
    local k = indent_level(ctx, items)
    if k then
      local op = k > 0 and ">" or "<"
      local nr = last - first + 1
      if math.abs(k) == 1 and g.contiguous then
        if n == 1 then
          local cur, rp = at_rows(ctx, first, first)
          key(ctx, "indent-block", op .. op, op .. op, 2, cur, rp)
        else
          local cur, rp = at_rows(ctx, first, first)
          key(ctx, "indent-block", n .. op .. op, n .. op .. op, digits(n) + 2, cur, rp)
          key(ctx, "indent-block", op .. (n - 1) .. "j", op .. (n - 1) .. "j", 2 + digits(n - 1), cur, rp)
          local cur2, rp2 = at_rows(ctx, first, last)
          key(ctx, "indent-block", op .. "ip", op .. "ip", 3, cur2, rp2)
          key(ctx, "indent-block", op .. "ap", op .. "ap", 3, cur2, rp2)
          key(ctx, "indent-block", op .. "i{", op .. "i{", 3, cur2, rp2)
        end
      end
      if rng then
        local cur, rp = at_rows(ctx, first, first)
        local body = string.rep(op, math.abs(k))
        ex(ctx, "indent-block", nr, rng, filter .. body, "", cur, rp)
      end
    end
  end

  -- Case change over many lines.
  if n >= 2 and g.case_only and g.contiguous then
    local all_up, all_low = true, true
    for _, it in ipairs(items) do
      all_up = all_up and it.new == it.new:upper()
      all_low = all_low and it.new == it.new:lower()
    end
    local g2 = all_up and "gU" or (all_low and "gu" or "g~")
    local tail = g2 == "g~" and "~" or g2:sub(2)
    local cur, rp = at_rows(ctx, first, first)
    key(ctx, "case-change", n .. g2 .. tail, n .. g2 .. tail, digits(n) + 3, cur, rp)
    key(ctx, "case-change", g2 .. (n - 1) .. "j", g2 .. (n - 1) .. "j", 3 + digits(n - 1), cur, rp)
    local cur2, rp2 = at_rows(ctx, first, last)
    key(ctx, "case-change", g2 .. "ip", g2 .. "ip", 4, cur2, rp2)
  end

  -- Comment toggle.
  local cs = buf_opt(ctx, "commentstring", "")
  local leader = vim.trim(cs:match("^(.-)%%s") or "")
  if leader ~= "" and g.contiguous then
    local hit = true
    for _, it in ipairs(items) do
      local t = it.new ~= "" and it.new or it.old
      if not t:find(leader, 1, true) then
        hit = false
        break
      end
    end
    if hit then
      local cur, rp = at_rows(ctx, first, first)
      if n == 1 then
        mapped(ctx, "comment-gc", "gcc", 3, cur, rp)
      else
        mapped(ctx, "comment-gc", "gc" .. (n - 1) .. "j", 3 + digits(n - 1), cur, rp)
        mapped(ctx, "comment-gc", n .. "gcc", digits(n) + 3, cur, rp)
        local cur2, rp2 = at_rows(ctx, first, last)
        mapped(ctx, "comment-gc", "gcip", 4, cur2, rp2)
      end
    end
  end
end

-- Whole-line shapes ----------------------------------------------------------

local function del_lines(ctx, sh)
  local n, row = sh.n, sh.row
  local kd_ok = ctx.kd and ctx.kd.dd >= cost.min_run_edit.dd
  if n < cost.min_run_edit.dd or not kd_ok then
    return
  end
  local cur, rp = at_rows(ctx, row, row)
  key(ctx, "count-dd", n .. "dd", n .. "dd", digits(n) + 2, cur, rp)
  key(ctx, "count-dd", "d" .. (n - 1) .. "j", "d" .. (n - 1) .. "j", 2 + digits(n - 1), cur, rp)
  ex(ctx, "count-dd", n, row .. "," .. (row + n - 1), "d", "", cur, rp)
end

local function move(ctx, sh)
  local from, n, dest = sh.from, sh.n, sh.dest
  local last = from + n - 1
  local cur, rp = at_rows(ctx, from, from)
  local rng = from .. "," .. last .. "m" .. dest
  local rel = dest > last and ("+" .. (dest - last)) or tostring(dest - from)
  local body = "m" .. rel
  local c = rsel(n) + 2 + chars(body)
  local label = n == 1 and (":m " .. rel) or (":'<,'>m '" .. (dest > last and ">" or "<") ..
    (dest > last and ("+" .. (dest - last)) or ("-" .. (from - dest))))
  add(ctx, { idiom = "move-lines", label = label, ex = rng, cost = c }, cur, rp)
  -- dd / p
  local dn = n > 1 and tostring(n) or ""
  if dest > last then
    local j = dest - n - from
    local keys = dn .. "dd" .. (j > 0 and (j .. "j") or "") .. "p"
    key(ctx, "move-lines", keys, keys, #dn + 2 + (j > 0 and digits(j) + 1 or 0) + 1, cur, rp)
  else
    local up = from - dest - 1
    local keys = dn .. "dd" .. (up > 1 and (up .. "k") or (up == 1 and "k" or "")) .. "P"
    key(ctx, "move-lines", keys, keys, #dn + 2 + (up > 1 and digits(up) + 1 or (up == 1 and 1 or 0)) + 1, cur, rp)
  end
end

local function dup(ctx, sh)
  local row, n = sh.row, sh.n
  local last = row + n - 1
  local cur, rp = at_rows(ctx, row, row)
  if sh.where == "below" then
    if n == 1 then
      key(ctx, "dup-lines", "yyp", "yyp", 3, cur, rp)
      add(ctx, { idiom = "dup-lines", label = ":t.", ex = row .. "t" .. row, cost = 4 }, cur, rp)
    else
      local keys = n .. "yy" .. (n - 1) .. "jp"
      key(ctx, "dup-lines", keys, keys, digits(n) + 2 + digits(n - 1) + 1 + 1, cur, rp)
      ex(ctx, "dup-lines", n, row .. "," .. last, "t" .. last, "", cur, rp, "t'>")
    end
  else
    local dn = n > 1 and tostring(n) or ""
    key(ctx, "dup-lines", dn .. "yyP", dn .. "yyP", #dn + 3, cur, rp)
    ex(ctx, "dup-lines", n, row .. "," .. last, "t" .. (row - 1), "", cur, rp, "t'<-1")
  end
end

local function join(ctx, sh)
  local row, n = sh.row, sh.n
  local cur, rp = at_rows(ctx, row, row)
  if n == 2 then
    key(ctx, "join-lines", "J", "J", 1, cur, rp)
  else
    key(ctx, "join-lines", n .. "J", n .. "J", digits(n) + 1, cur, rp)
  end
  key(ctx, "join-lines", n == 2 and "gJ" or (n .. "gJ"), n == 2 and "gJ" or (n .. "gJ"), 2 + (n == 2 and 0 or digits(n)),
    cur, rp)
  ex(ctx, "join-lines", n, row .. "," .. (row + n - 1), "j", "", cur, rp)
end

-- Alignments -----------------------------------------------------------------

local function csuf(a, b)
  local n, max = 0, math.min(#a, #b)
  while n < max and a:byte(#a - n) == b:byte(#b - n) do
    n = n + 1
  end
  return n
end

local function boundary(s, i)
  local b = s:byte(i + 1)
  return not (b and b >= 0x80 and b < 0xC0)
end

-- A pure deletion or insertion can slide along repeated characters; every position
-- gives the same text, so try each (word boundaries often only fit one of them).
local function aligned(it)
  local out = { it }
  local lb, la = it.lb, it.la
  if it.old ~= "" and it.new == "" then
    local d = #it.old
    local pmin = math.max(0, #la - csuf(lb, la))
    for p = it.pre - 1, math.max(pmin, it.pre - 40), -1 do
      if boundary(lb, p) and boundary(lb, p + d) then
        out[#out + 1] = {
          row = it.row, lb = lb, la = la, pre = p, suf = #lb - p - d, old = lb:sub(p + 1, p + d), new = "",
        }
      end
    end
  elseif it.old == "" and it.new ~= "" then
    local d = #it.new
    local pmin = math.max(0, #lb - csuf(lb, la))
    for p = it.pre - 1, math.max(pmin, it.pre - 40), -1 do
      if boundary(la, p) and boundary(la, p + d) then
        out[#out + 1] = {
          row = it.row, lb = lb, la = la, pre = p, suf = #lb - p, old = "", new = la:sub(p + 1, p + d),
        }
      end
    end
  end
  return out
end

-- Entry points ---------------------------------------------------------------

--- Candidates for a span, cheapest first, at most cost.max_candidates.
--- Distinct idioms are preferred over many variants of the same idiom.
---@param span VimCoach.Span
---@param shape VimCoach.Shape
---@return VimCoach.Candidate[]
function M.generate(span, shape)
  local ctx = make_ctx(span, shape)
  local kind = shape.kind
  if kind == "intra" then
    local bs = ctx.kd and ctx.kd.bs >= cost.min_run_edit.bs
    for _, it in ipairs(aligned(shape.items[1])) do
      intra(ctx, it)
      if bs then
        backspaces(ctx, it)
      end
    end
    group(ctx)
  elseif kind == "per_line" then
    group(ctx)
  elseif kind == "del_lines" then
    del_lines(ctx, shape)
  elseif kind == "move" then
    move(ctx, shape)
  elseif kind == "dup" then
    dup(ctx, shape)
  elseif kind == "join" then
    join(ctx, shape)
  end

  local list, seen = {}, {}
  for _, c in ipairs(ctx.out) do
    local id = (c.keys or "ex:" .. c.ex) .. "@" .. (c.cursor and (c.cursor[1] .. "," .. c.cursor[2]) or "")
    if not seen[id] and c.cost >= 1 then
      seen[id] = true
      list[#list + 1] = c
    end
  end
  table.sort(list, before)

  -- Two variants per idiom first, then fill up.
  local picked, per, taken = {}, {}, {}
  for i, c in ipairs(list) do
    if #picked < cost.max_candidates and (per[c.idiom] or 0) < 2 then
      per[c.idiom] = (per[c.idiom] or 0) + 1
      taken[i] = true
      picked[#picked + 1] = c
    end
  end
  for i, c in ipairs(list) do
    if #picked < cost.max_candidates and not taken[i] then
      picked[#picked + 1] = c
    end
  end
  table.sort(picked, before)
  for _, c in ipairs(picked) do
    c.seq = nil
  end
  return picked
end

--- Modeled keystrokes without the idiom (design doc 4.2), excluding typed text and <Esc>.
---@param shape VimCoach.Shape
---@return integer
function M.model_naive(shape)
  local m = cost.model
  local function item_cost(it)
    local c = chars(it.old) * m.char
    if it.new ~= "" then
      c = c + math.max(m.mode_switch - 1, 0)
    end
    return c
  end
  local kind = shape.kind
  if kind == "intra" or kind == "per_line" then
    local total = 0
    for _, it in ipairs(shape.items) do
      total = total + item_cost(it)
    end
    return total + (#shape.items - 1) * m.line_move
  elseif kind == "del_lines" then
    return shape.n * m.char
  elseif kind == "move" then
    local dist = shape.dest > shape.from and (shape.dest - shape.from - shape.n + 1) or (shape.from - shape.dest)
    return 2 * m.char + dist * m.line_move
  elseif kind == "dup" then
    local total = 0
    for _, l in ipairs(shape.lines) do
      total = total + chars(l) * m.char
    end
    return total + math.max(m.mode_switch - 1, 0) + (shape.n - 1) * m.line_move
  elseif kind == "join" then
    return (shape.n - 1) * (2 * m.char)
  end
  return 0
end

return M
