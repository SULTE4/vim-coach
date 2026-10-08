local store = require("vim_coach.store")
local cost = require("vim_coach.cost")

local DAY = 86400
local SENTINEL = "SENTINEL_SECRET_CODE_xyz"

local function ev(id, idiom, ts, naive, ideal)
  return { edit_id = id, ts = ts or os.time(), idiom = idiom or "ci-quote", alts = {}, ft = "lua", scale = 1,
    naive = naive or 14, ideal = ideal or 3, src = "edit", measured = false }
end

local function read_json(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s, vim.json.decode(s)
end

local function write_json(path, t)
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode(t))
  f:close()
end

describe("store", function()
  local path
  before_each(function()
    path = vim.fn.tempname() .. ".json"
    store.setup(path)
  end)
  after_each(function()
    store.stop()
    os.remove(path)
    os.remove(path .. ".tmp")
  end)

  it("never uses the real data file", function()
    assert.equals(path, store.path())
    assert.is_not.equals(vim.fn.stdpath("data") .. "/vim_coach.json", store.path())
  end)

  it("tolerates corrupt and missing files", function()
    local f = io.open(path, "w")
    f:write("{not json")
    f:close()
    assert.has_no.errors(function()
      store.setup(path)
    end)
    assert.equals(0, #store.events())
    store.setup(path .. ".missing")
    assert.equals(0, #store.events())
  end)

  it("round trips events, learned, dismissed", function()
    store.add(ev("a1"))
    store.add(ev("a2", "visual-block", nil, 60, 6))
    store.dismiss("find-char")
    store.mark_learned("count-jk", 1234)
    store.save(true)
    local _, data = read_json(path)
    assert.equals(1, data.version)
    assert.equals(2, #data.events)
    assert.same({ "find-char" }, data.dismissed)
    assert.equals(1234, data.learned["count-jk"])

    store.setup(path)
    assert.equals(2, #store.events())
    assert.is_true(store.state().dismissed["find-char"])
    assert.equals(1234, store.state().learned["count-jk"])
  end)

  it("writes an empty file that decodes with the right shapes", function()
    store.save(true)
    local s = read_json(path)
    assert.is_truthy(s:find('"rollup":{}', 1, true))
    assert.is_truthy(s:find('"learned":{}', 1, true))
    assert.is_truthy(s:find('"dismissed":[]', 1, true))
  end)

  it("saves asynchronously via the debounce timer", function()
    store.add(ev("t1"))
    assert.is_nil(vim.uv.fs_stat(path))
    store.save(false)
    vim.wait(2000, function()
      return vim.uv.fs_stat(path) ~= nil
    end, 10)
    assert.is_not_nil(vim.uv.fs_stat(path))
    assert.is_nil(vim.uv.fs_stat(path .. ".tmp"))
  end)

  it("rolls up old events into the right ISO week", function()
    local old = os.time() - 100 * DAY
    local f = io.open(path, "w")
    f:write(vim.json.encode({ version = 1, events = {
      ev("o1", "ci-quote", old, 14, 3), ev("o2", "ci-quote", old, 10, 2), ev("n1", "ci-quote", nil),
    }, rollup = vim.empty_dict(), learned = vim.empty_dict(), dismissed = {} }))
    f:close()
    store.setup(path)
    assert.equals(1, #store.events())
    local key = os.date("%G-W%V", old)
    assert.same({ count = 2, saved = 19 }, store.rollup()["ci-quote"][key])
    assert.is_true(old < os.time() - cost.retain_days * DAY)
    store.save(true)
    local _, data = read_json(path)
    assert.equals(1, #data.events)
    assert.equals(2, data.rollup["ci-quote"][key].count)
    -- second load must not double count
    store.setup(path)
    assert.equals(2, store.rollup()["ci-quote"][key].count)
  end)

  it("merges with another instance without losing or duplicating events", function()
    store.add(ev("mine"))
    store.add(ev("shared"))
    -- another instance wrote its own events plus the shared one
    write_json(path, { version = 1, events = { ev("shared"), ev("theirs") },
      rollup = { ["ci-quote"] = { ["2020-W01"] = { count = 4, saved = 40 } } },
      learned = { ["find-char"] = 50 }, dismissed = { "hjkl" }, adopt = { ["find-char"] = { count = 3, days = 1, last_day = "2020-01-01" } } })
    store.mark_learned("find-char", 100)
    store.save(true)
    local _, data = read_json(path)
    local seen = {}
    for _, e in ipairs(data.events) do
      seen[e.edit_id] = (seen[e.edit_id] or 0) + 1
    end
    assert.same({ mine = 1, shared = 1, theirs = 1 }, seen)
    assert.equals(40, data.rollup["ci-quote"]["2020-W01"].saved)
    assert.equals(50, data.learned["find-char"]) -- earliest ts wins
    assert.same({ "hjkl" }, data.dismissed)
    assert.equals(3, data.adopt["find-char"].count)
    assert.equals(3, #store.events())
  end)

  it("dismiss and undismiss survive a merge", function()
    store.dismiss("hjkl")
    store.save(true)
    store.undismiss("hjkl")
    store.save(true)
    local _, data = read_json(path)
    assert.same({}, data.dismissed)
    assert.is_nil(store.state().dismissed["hjkl"])
  end)

  it("unlearn is not resurrected by the disk copy", function()
    store.mark_learned("hjkl", 5)
    store.save(true)
    store.unlearn("hjkl")
    store.save(true)
    local _, data = read_json(path)
    assert.is_nil(data.learned["hjkl"])
  end)

  it("record_use adopts after enough uses across days", function()
    local d1 = os.time() - 3 * DAY
    for i = 1, cost.adopt_uses do
      assert.is_false(store.record_use("find-char", d1 + i))
    end
    assert.is_nil(store.state().learned["find-char"])
    local d2 = d1 + DAY
    assert.is_true(store.record_use("find-char", d2))
    assert.equals(d2, store.state().learned["find-char"])
    assert.is_false(store.record_use("find-char", d2 + 1)) -- already learned
  end)

  it("reset clears memory and file", function()
    store.add(ev("r1"))
    store.save(true)
    store.reset()
    assert.equals(0, #store.events())
    assert.is_nil(vim.uv.fs_stat(path))
  end)

  it("new_id returns 6 base36 chars", function()
    local a, b = store.new_id(), store.new_id()
    assert.is_truthy(a:match("^[0-9a-z]+$"))
    assert.equals(6, #a)
    assert.is_not.equals(a, b)
  end)

  it("never writes code text", function()
    local e = ev("p1")
    store.add(e)
    store.record_use("find-char")
    -- the sentinel only ever lives in session-only data, not in the event
    local finding = { event = e, label = "ci\"", example = { before = { SENTINEL }, after = { SENTINEL } } }
    assert.is_not_nil(finding)
    store.save(true)
    local s = read_json(path)
    assert.is_nil(s:find(SENTINEL, 1, true))
    assert.is_nil(s:find("example", 1, true))
  end)
end)

describe("store ignore option", function()
  local config = require("vim_coach.config")
  local store = require("vim_coach.store")

  after_each(function()
    config.setup({})
  end)

  it("treats config ignore ids as dismissed without persisting them", function()
    local path = vim.fn.tempname()
    config.setup({ ignore = { "count-jk" } })
    store.setup(path)
    assert.is_true(store.state().dismissed["count-jk"])
    store.dismiss("ciw")
    assert.is_true(store.state().dismissed["ciw"])
    assert.is_true(store.state().dismissed["count-jk"])
    store.save(true)
    local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.same({ "ciw" }, data.dismissed)
    config.setup({})
    assert.is_nil(store.state().dismissed["count-jk"])
    store.stop()
  end)
end)
