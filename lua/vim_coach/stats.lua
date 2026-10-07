-- :VimCoach stats floating window. Everything is computed when opened.
local catalog = require("vim_coach.catalog")

local M = {}

local CATEGORIES = { "motions", "text-objects", "operators", "insert", "visual", "ex", "macros", "habits" }
local FOOTER = "Savings are estimates from observed keys and modeled edits, not exact measurements."
local HELP = "q close  d dismiss  u undismiss  L learned  e example"

--- Learning value for an idiom from score.rank output (list of rows or map).
local function rank_value(ranked, id)
  if type(ranked) ~= "table" then
    return nil
  end
  local v = ranked[id]
  if v == nil then
    for _, row in ipairs(ranked) do
      if row.id == id or row.idiom == id then
        v = row
        break
      end
    end
  end
  if type(v) == "table" then
    v = v.value or v.score or v.learning_value
  end
  return type(v) == "number" and v or nil
end

local function sum_rollup(rollup, id)
  local count, saved = 0, 0
  for _, b in pairs((rollup or {})[id] or {}) do
    count = count + (b.count or 0)
    saved = saved + (b.saved or 0)
  end
  return count, saved
end

local function trend(w)
  local this, last = w.this.saved, w.last.saved
  if last == 0 and this == 0 then
    return "-"
  elseif last == 0 then
    return "^ new"
  end
  local pct = math.floor((this - last) / last * 100 + 0.5)
  if pct == 0 then
    return "= 0%"
  end
  return (pct > 0 and "^ +" or "v ") .. pct .. "%"
end

--- Pure renderer.
---@param events VimCoach.Event[]
---@param rollup table
---@param state VimCoach.State
---@param now integer
---@return string[] lines
---@return table<integer, string> line_to_id
function M.render(events, rollup, state, now)
  local score = require("vim_coach.score")
  local by = score.by_idiom(events)
  local ranked = score.rank(by, catalog, state, now)
  local next_id, because = score.next_to_learn(ranked, catalog, state)

  local lines, map = {}, {}
  local function add(text, id)
    lines[#lines + 1] = text
    if id then
      map[#lines] = id
    end
  end

  -- Per-idiom data.
  local data = {}
  for id, entry in pairs(catalog) do
    if not entry.concept then
      local count, saved = sum_rollup(rollup, id)
      for _, e in ipairs(by[id] or {}) do
        count = count + 1
        saved = saved + math.max(0, e.naive - e.ideal)
      end
      if count > 0 then
        data[id] = { count = count, saved = saved, value = rank_value(ranked, id) }
      end
    end
  end

  if next_id and catalog[next_id] then
    add(("Next to learn: %s (%s)"):format(catalog[next_id].example, next_id), next_id)
    if because then
      add(("  learn this first, it unlocks %s"):format(because))
    end
    local w = score.weekly(events, rollup, next_id, now)
    local per_week = math.floor((w.this.saved + w.last.saved) / 2)
    if per_week > 0 then
      add(("  potential: about %d keystrokes per week"):format(per_week))
    end
  else
    add("Next to learn: nothing yet, keep editing and check back")
  end
  add("")

  for _, cat in ipairs(CATEGORIES) do
    local ids = {}
    for id, entry in pairs(catalog) do
      if entry.category == cat and data[id] then
        ids[#ids + 1] = id
      end
    end
    if #ids > 0 then
      table.sort(ids, function(a, b)
        local va, vb = data[a].value or 0, data[b].value or 0
        if va ~= vb then
          return va > vb
        end
        if data[a].saved ~= data[b].saved then
          return data[a].saved > data[b].saved
        end
        return a < b
      end)
      add(cat:upper())
      for _, id in ipairs(ids) do
        local d, entry = data[id], catalog[id]
        local w = score.weekly(events, rollup, id, now)
        local value = d.value and ("%.1f"):format(d.value) or "-"
        add(("  %-14s %-40s x%-4d saved %-5d %-8s value %s"):format(
          entry.example, entry.desc, d.count, d.saved, trend(w), value), id)
      end
      add("")
    end
  end

  local function list(title, set)
    local ids = {}
    for id in pairs(set or {}) do
      if catalog[id] then
        ids[#ids + 1] = id
      end
    end
    if #ids > 0 then
      table.sort(ids)
      add(title)
      for _, id in ipairs(ids) do
        add(("  %-14s (%s)"):format(catalog[id].example, id), id)
      end
      add("")
    end
  end
  list("LEARNED", state.learned)
  list("DISMISSED", state.dismissed)

  add(FOOTER)
  add(HELP)
  return lines, map
end

local function show_example(id)
  local ex = require("vim_coach.session").example(id)
  if not ex then
    vim.notify("vim-coach: no example recorded for " .. id .. " this session")
    return
  end
  local out = { "vim-coach example for " .. id, "before:" }
  for _, l in ipairs(ex.before) do
    out[#out + 1] = "  " .. l
  end
  out[#out + 1] = "after:"
  for _, l in ipairs(ex.after) do
    out[#out + 1] = "  " .. l
  end
  vim.notify(table.concat(out, "\n"))
end

function M.open()
  local store = require("vim_coach.store")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vim_coach"

  local win, map

  local function draw()
    local lines
    lines, map = M.render(store.events(), store.rollup(), store.state(), os.time())
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local width = 0
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    local w = math.min(width + 2, math.floor(vim.o.columns * 0.8))
    local h = math.min(#lines, math.floor(vim.o.lines * 0.8))
    local cfg = {
      relative = "editor", width = w, height = h,
      row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    }
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, cfg)
    else
      cfg.style = "minimal"
      cfg.border = "rounded"
      cfg.title = " vim-coach "
      win = vim.api.nvim_open_win(buf, true, cfg)
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = true
    end
  end
  draw()

  local function under_cursor()
    return map[vim.api.nvim_win_get_cursor(win)[1]]
  end
  local function act(fn)
    return function()
      local id = under_cursor()
      if not id then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(win)
      fn(id)
      draw()
      pos[1] = math.min(pos[1], vim.api.nvim_buf_line_count(buf))
      pcall(vim.api.nvim_win_set_cursor, win, pos)
    end
  end
  local function close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function key(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  key("q", close)
  key("<Esc>", close)
  key("d", act(store.dismiss))
  key("u", act(store.undismiss))
  key("L", act(function(id)
    store.mark_learned(id, os.time())
  end))
  key("e", function()
    local id = under_cursor()
    if id then
      show_example(id)
    end
  end)
end

return M
