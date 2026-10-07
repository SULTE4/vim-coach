-- JSON persistence (design doc 5.2). Only idiom IDs and numbers are written.
-- Saves are debounced and async; merge-on-write keeps multiple instances safe.
local cost = require("vim_coach.cost")

local uv = vim.uv or vim.loop

local M = {}

local file_path ---@type string?
local events = {} ---@type VimCoach.Event[]
local ids = {} ---@type table<string, boolean>
local rollup = {} ---@type table<string, table<string, {count:integer, saved:integer}>>
local learned = {} ---@type table<string, integer>
local dismissed = {} ---@type table<string, boolean>
local adopt = {} ---@type table<string, {count:integer, days:integer, last_day:string}>
local undismissed = {} ---@type table<string, boolean>  removed this session, do not resurrect
local unlearned = {} ---@type table<string, boolean>
local dirty = false
local writing = false
local timer ---@type uv.uv_timer_t?
local seeded = false

local function week_key(ts)
  return os.date("%G-W%V", ts)
end

local function default_path()
  return vim.fn.stdpath("data") .. "/vim_coach.json"
end

---@param str string
---@return table?
local function decode(str)
  local ok, data = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    return data
  end
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  if not data or data == "" then
    return nil
  end
  return decode(data)
end

local function valid_event(e)
  return type(e) == "table" and type(e.edit_id) == "string" and type(e.ts) == "number"
    and type(e.idiom) == "string" and type(e.naive) == "number" and type(e.ideal) == "number"
end

local function add_bucket(idiom, key, count, saved)
  local r = rollup[idiom]
  if not r then
    r = {}
    rollup[idiom] = r
  end
  local b = r[key]
  if not b then
    b = { count = 0, saved = 0 }
    r[key] = b
  end
  b.count = b.count + count
  b.saved = b.saved + saved
end

local function cutoff()
  return os.time() - cost.retain_days * 86400
end

--- Merge a decoded file table into memory. `old_events_ok` keeps aged events (setup rolls them up).
local function merge(data)
  local cut = cutoff()
  local added = false
  for _, e in ipairs(data.events or {}) do
    if valid_event(e) and not ids[e.edit_id] and e.ts >= cut then
      e.alts = e.alts or {}
      events[#events + 1] = e
      ids[e.edit_id] = true
      added = true
    end
  end
  if added then
    table.sort(events, function(a, b)
      return a.ts < b.ts
    end)
  end
  if type(data.rollup) == "table" then
    for idiom, buckets in pairs(data.rollup) do
      if type(buckets) == "table" then
        for key, b in pairs(buckets) do
          if type(b) == "table" then
            local r = rollup[idiom]
            if not r then
              r = {}
              rollup[idiom] = r
            end
            local cur = r[key]
            if not cur then
              r[key] = { count = b.count or 0, saved = b.saved or 0 }
            else
              cur.count = math.max(cur.count, b.count or 0)
              cur.saved = math.max(cur.saved, b.saved or 0)
            end
          end
        end
      end
    end
  end
  if type(data.learned) == "table" then
    for id, ts in pairs(data.learned) do
      if type(ts) == "number" and not unlearned[id] and (not learned[id] or ts < learned[id]) then
        learned[id] = ts
      end
    end
  end
  if type(data.dismissed) == "table" then
    for _, id in ipairs(data.dismissed) do
      if type(id) == "string" and not undismissed[id] then
        dismissed[id] = true
      end
    end
  end
  if type(data.adopt) == "table" then
    for id, a in pairs(data.adopt) do
      if type(a) == "table" and type(a.count) == "number" and (not adopt[id] or a.count > adopt[id].count) then
        adopt[id] = { count = a.count, days = a.days or 0, last_day = a.last_day or "" }
      end
    end
  end
end

local function rollup_old()
  local cut = cutoff()
  local keep, moved = {}, false
  for _, e in ipairs(events) do
    if e.ts < cut then
      add_bucket(e.idiom, week_key(e.ts), 1, e.naive - e.ideal)
      ids[e.edit_id] = nil
      moved = true
    else
      keep[#keep + 1] = e
    end
  end
  if moved then
    events = keep
    dirty = true
  end
end

local function clear_memory()
  events, ids, rollup, learned, dismissed, adopt = {}, {}, {}, {}, {}, {}
  undismissed, unlearned = {}, {}
  dirty = false
end

local function stop_timer()
  if timer and timer:is_active() then
    timer:stop()
  end
end

local function encode()
  local dis = {}
  for id in pairs(dismissed) do
    dis[#dis + 1] = id
  end
  table.sort(dis)
  local out = {
    version = 1,
    events = events,
    rollup = next(rollup) and rollup or vim.empty_dict(),
    learned = next(learned) and learned or vim.empty_dict(),
    dismissed = dis,
    adopt = next(adopt) and adopt or vim.empty_dict(),
  }
  return vim.json.encode(out)
end

---@return string? json
local function prepare()
  if not file_path then
    return nil
  end
  local disk = read_file(file_path)
  if disk then
    merge(disk)
  end
  local ok, json = pcall(encode)
  if not ok then
    return nil
  end
  return json
end

local function write_sync(json)
  local tmp = file_path .. ".tmp"
  vim.fn.mkdir(vim.fn.fnamemodify(file_path, ":h"), "p")
  local fd = uv.fs_open(tmp, "w", 420)
  if not fd then
    return false
  end
  local ok = uv.fs_write(fd, json, 0)
  uv.fs_close(fd)
  if not ok then
    return false
  end
  return uv.fs_rename(tmp, file_path) and true or false
end

local function write_async(json)
  local path = file_path
  writing = true
  local function done(ok)
    writing = false
    if not ok then
      dirty = true
    end
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. ".tmp"
  uv.fs_open(tmp, "w", 420, function(err, fd)
    if err or not fd then
      return done(false)
    end
    uv.fs_write(fd, json, 0, function(werr)
      uv.fs_close(fd, function()
        if werr then
          return done(false)
        end
        uv.fs_rename(tmp, path, function(rerr)
          done(not rerr)
        end)
      end)
    end)
  end)
end

---@param sync boolean?
function M.save(sync)
  if not file_path then
    return
  end
  stop_timer()
  if not sync and writing then
    M.touch()
    return
  end
  local json = prepare()
  if not json then
    return
  end
  dirty = false
  if sync then
    if not write_sync(json) then
      dirty = true
    end
  else
    write_async(json)
  end
end

--- Mark dirty and arm the single debounce timer.
function M.touch()
  dirty = true
  if not file_path then
    return
  end
  if not timer then
    timer = uv.new_timer()
  end
  if timer and not timer:is_active() then
    timer:start(cost.save_debounce_ms, 0, vim.schedule_wrap(function()
      M.save(false)
    end))
  end
end

---@param path string?
function M.setup(path)
  stop_timer()
  clear_memory()
  file_path = path or default_path()
  local data = read_file(file_path)
  if data then
    -- load aged events too, then roll them up
    for _, e in ipairs(data.events or {}) do
      if valid_event(e) and not ids[e.edit_id] then
        e.alts = e.alts or {}
        events[#events + 1] = e
        ids[e.edit_id] = true
      end
    end
    data.events = nil
    merge(data)
    table.sort(events, function(a, b)
      return a.ts < b.ts
    end)
    rollup_old()
  end
  if dirty then
    M.touch()
  end
end

function M.stop()
  if file_path and dirty then
    M.save(true)
  end
  if timer then
    stop_timer()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

---@param ev VimCoach.Event
function M.add(ev)
  if ids[ev.edit_id] then
    return
  end
  events[#events + 1] = ev
  ids[ev.edit_id] = true
  M.touch()
end

---@return VimCoach.Event[]
function M.events()
  return events
end

function M.rollup()
  return rollup
end

---@return VimCoach.State
function M.state()
  return { learned = learned, dismissed = dismissed }
end

---@param id string
function M.dismiss(id)
  dismissed[id] = true
  undismissed[id] = nil
  M.touch()
end

---@param id string
function M.undismiss(id)
  dismissed[id] = nil
  undismissed[id] = true
  M.touch()
end

---@param id string
---@param ts integer?
function M.mark_learned(id, ts)
  learned[id] = ts or os.time()
  unlearned[id] = nil
  M.touch()
end

---@param id string
function M.unlearn(id)
  learned[id] = nil
  unlearned[id] = true
  adopt[id] = nil
  M.touch()
end

--- Count one real use of an idiom. True when this use made it learned.
---@param id string
---@param now integer?
---@return boolean
function M.record_use(id, now)
  now = now or os.time()
  local a = adopt[id]
  if not a then
    a = { count = 0, days = 0, last_day = "" }
    adopt[id] = a
  end
  local day = os.date("%Y-%m-%d", now)
  a.count = a.count + 1
  if a.last_day ~= day then
    a.days = a.days + 1
    a.last_day = day
  end
  M.touch()
  if not learned[id] and a.count >= cost.adopt_uses and a.days >= cost.adopt_days then
    learned[id] = now
    unlearned[id] = nil
    return true
  end
  return false
end

function M.reset()
  stop_timer()
  clear_memory()
  if file_path then
    uv.fs_unlink(file_path)
  end
end

---@return string
function M.new_id()
  if not seeded then
    math.randomseed(os.time() + (uv.hrtime() % 1000003))
    seeded = true
  end
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local out = {}
  for i = 1, 6 do
    local n = math.random(1, 36)
    out[i] = chars:sub(n, n)
  end
  return table.concat(out)
end

---@return string
function M.path()
  return file_path or default_path()
end

return M
