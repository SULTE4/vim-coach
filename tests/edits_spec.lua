local cost = require("vim_coach.cost")

local reports = {}
local counters, total

local function zero()
  return { total = 0, printable = 0, bs = 0, cw = 0, cu = 0, x = 0, dd = 0, arrows = 0, esc = 0 }
end

-- Fake modules so this spec does not depend on other agents' files.
package.loaded["vim_coach.sink"] = {
  report = function(f)
    table.insert(reports, f)
    return true
  end,
  used = function() end,
}
local use_keys = false
package.loaded["vim_coach.keys"] = {
  counters = function()
    return vim.deepcopy(counters)
  end,
  total = function()
    return counters.total
  end,
}

local edits = require("vim_coach.edits")
local verify = require("vim_coach.verify")
local config = require("vim_coach.config")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "tx", false)
end

local function bump(t)
  for k, v in pairs(t) do
    counters[k] = counters[k] + v
  end
end

local function wait_report(n)
  vim.wait(cost.edit_debounce_ms * 3 + 500, function()
    return #reports >= (n or 1)
  end, 10)
end

local function setup_buf(lines, cursor)
  vim.cmd("enew!")
  vim.bo.shiftwidth = 2
  vim.bo.expandtab = true
  vim.bo.commentstring = "-- %s"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd("set nomodified")
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
  edits.setup()
end

describe("edits", function()
  before_each(function()
    reports = {}
    counters = zero()
    config.setup({})
    verify.warm()
  end)
  after_each(function()
    edits.stop()
    verify.stop()
  end)

  it("replaces string contents typed with backspaces (modeled)", function()
    -- keys counters never move, so the cost is modeled from the diff
    setup_buf({ 'x = "hello world"' }, { 1, 15 })
    feed('a' .. string.rep("<BS>", 11) .. "bye<Esc>")
    wait_report()
    assert.equals(1, #reports)
    local f = reports[1]
    assert.equals("ci-quote", f.event.idiom)
    assert.equals("edit", f.event.src)
    assert.is_false(f.event.measured)
    assert.is_true(f.event.naive > f.event.ideal)
    assert.equals('ci"', f.label)
    assert.same({ 'x = "hello world"' }, f.example.before)
    assert.same({ 'x = "bye"' }, f.example.after)
    assert.is_truthy(f.since)
  end)

  it("measures naive cost from key counters", function()
    setup_buf({ 'x = "hello world"' }, { 1, 15 })
    feed('a' .. string.rep("<BS>", 11) .. "bye<Esc>")
    bump({ total = 1 + 11 + 3 + 1, printable = 3, bs = 11, esc = 1 })
    wait_report()
    local f = reports[1]
    assert.equals("ci-quote", f.event.idiom)
    assert.is_true(f.event.measured)
    assert.equals(12, f.event.naive) -- a + 11 BS, text and <Esc> excluded
    assert.equals(3, f.event.ideal)
    assert.equals("11 x <BS>", f.was)
  end)

  it("finds <C-w> for backspacing a word", function()
    setup_buf({ "let name = some_value" }, { 1, 20 })
    feed("a" .. string.rep("<BS>", 10) .. "other<Esc>")
    bump({ total = 1 + 10 + 5 + 1, printable = 5, bs = 10, esc = 1 })
    wait_report()
    local f = reports[1]
    assert.is_truthy(f)
    assert.is_true(f.event.naive - f.event.ideal >= 5)
  end)

  it("adds a prefix to 10 lines edited one by one", function()
    local lines = {}
    for i = 1, 10 do
      lines[i] = "item " .. i
    end
    setup_buf(lines)
    for _ = 1, 10 do
      feed("0i- <Esc>j")
    end
    wait_report()
    local f = reports[1]
    assert.is_truthy(f)
    assert.equals(10, f.event.scale)
    local ok = { ["visual-block"] = true, ["normal-range"] = true, ["subst-range"] = true }
    assert.is_true(ok[f.event.idiom] == true)
    assert.is_true(f.event.naive > 15)
    assert.equals("10 lines edited", f.was)
  end)

  it("reports the same substitution on many lines", function()
    local lines = {}
    for i = 1, 6 do
      lines[i] = "foo(" .. i .. ")"
    end
    setup_buf(lines)
    for _ = 1, 6 do
      feed("0ciwbar<Esc>j")
    end
    wait_report()
    assert.equals("subst-range", reports[1].event.idiom)
  end)

  it("detects deleting lines with repeated dd", function()
    setup_buf({ "a", "b", "c", "d", "e", "f", "g" }, { 2, 0 })
    for _ = 1, 5 do
      feed("dd")
    end
    bump({ total = 5, dd = 5 })
    wait_report()
    local f = reports[1]
    assert.equals("count-dd", f.event.idiom)
    assert.equals(5, f.event.naive)
    assert.equals(3, f.event.ideal)
    assert.equals("5 x dd", f.was)
  end)

  it("ignores undo and redo", function()
    setup_buf({ 'x = "hello world"' }, { 1, 15 })
    feed("ciwbye<Esc>")
    wait_report()
    reports = {}
    feed("u")
    vim.wait(cost.edit_debounce_ms * 2 + 200)
    feed("<C-r>")
    vim.wait(cost.edit_debounce_ms * 2 + 200)
    assert.equals(0, #reports)
  end)

  it("ignores edits while a macro executes", function()
    setup_buf({ 'x = "hello world"' })
    vim.fn.setreg("q", 'f"ci"bye')
    feed("@q")
    vim.wait(cost.edit_debounce_ms * 2 + 200)
    assert.equals(0, #reports)
    -- control: the same edit typed by hand is found
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed('f"ci"abcdef<Esc>')
    wait_report()
    assert.equals("ci-quote", reports[1].event.idiom)
  end)

  it("ends a normal-mode span after the debounce", function()
    setup_buf({ "keep this, drop that" }, { 1, 9 })
    feed(string.rep("x", 11))
    assert.equals(0, #reports) -- finalization is deferred, never inside the edit
    local t0 = vim.uv.hrtime()
    wait_report()
    local waited = (vim.uv.hrtime() - t0) / 1e6
    assert.is_true(waited >= cost.edit_debounce_ms * 0.8, "waited " .. waited)
    assert.equals("delete-eol", reports[1].event.idiom)
    assert.same({ "keep this" }, reports[1].example.after)
  end)

  it("skips excluded and oversized buffers", function()
    vim.cmd("enew!")
    vim.bo.filetype = "help"
    edits.setup()
    assert.is_false(edits.attach(0))
    vim.cmd("enew!")
    vim.bo.buftype = "nofile"
    assert.is_false(edits.attach(0))
    vim.cmd("enew!")
    local big = {}
    for i = 1, cost.max_lines + 1 do
      big[i] = "x"
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, big)
    assert.is_false(edits.attach(0))
  end)

  it("reports dot-repeat when the same shape repeats", function()
    setup_buf({ "alpha one", "beta two", "gamma three", "delta four" })
    for _ = 1, 4 do
      feed("0ciwXY<Esc>")
      bump({ total = 6, printable = 2, esc = 1 })
      vim.wait(cost.edit_debounce_ms + 100)
      feed("j")
    end
    wait_report(1)
    local seen
    for _, f in ipairs(reports) do
      if f.event.idiom == "dot-repeat" then
        seen = f
      end
    end
    assert.is_truthy(seen)
    assert.equals(1, seen.event.ideal)
  end)

  it("counts retyped text for dot-repeat of per-line prefixes", function()
    setup_buf({ "one", "two", "three", "four", "five" })
    for i = 1, 5 do
      feed("I-- <Esc>")
      bump({ total = 5, printable = 3, esc = 1 })
      edits.flush(0)
      if i == 3 then
        break
      end
      feed("j")
    end
    local f = reports[#reports]
    assert.is_truthy(f)
    assert.equals(3, #reports == 1 and 3 or #reports)
    assert.equals("dot-repeat", f.event.idiom)
    assert.equals(1, f.event.ideal)
    assert.equals(5, f.event.naive)
    assert.is_true(f.event.naive > f.event.ideal)
  end)

  it("keeps the shadow in sync across several edits", function()
    setup_buf({ "one", "two", "three", "four", "five" })
    feed("jddjdd")
    vim.wait(cost.edit_debounce_ms + 200)
    feed("Gox<Esc>")
    vim.wait(cost.edit_debounce_ms + 200)
    reports = {}
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("ciwuno<Esc>")
    wait_report()
    local f = reports[1]
    if f then
      assert.same({ "one" }, { f.example.before[1] })
    end
  end)

  it("shadow copy matches the buffer after mixed edits", function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = "line " .. i .. " text"
    end
    setup_buf(lines)
    local buf = vim.api.nvim_get_current_buf()
    local function check()
      edits.flush(buf)
      assert.same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), edits._shadow(buf))
    end
    feed("5Gdd")
    check()
    feed("10Goinserted<CR>two<Esc>")
    check()
    feed("3Gddp")
    check()
    feed("gg3J")
    check()
    feed("u")
    check()
    feed("<C-r>")
    check()
    feed("Gdgg")
    check()
    feed("ihello<Esc>")
    check()
    vim.cmd("%s/e/E/")
    check()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x", "y", "z" })
    check()
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, {})
    check()
  end)
end)
