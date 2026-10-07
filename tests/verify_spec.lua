local verify = require("vim_coach.verify")

local function span(before, after, cursor)
  return {
    buf = vim.api.nvim_get_current_buf(),
    ft = "",
    before = before,
    after = after,
    first_row = 1,
    cursor_before = cursor or { 1, 0 },
    measured = false,
    since = 0,
  }
end

describe("verify.texts", function()
  after_each(function()
    verify.stop()
  end)

  it("keeps only candidates that reproduce the after text", function()
    local s = span({ 'x = "hello world"' }, { 'x = "bye"' }, { 1, 6 })
    local res = verify.texts(s, {
      { idiom = "ci-quote", label = 'ci"', keys = 'ci"bye', cost = 3 },
      { idiom = "ciw", label = "ciw", keys = "ciwbye", cost = 3 },
    }, 200)
    assert.same({ true, false }, res)
  end)

  it("runs ex candidates with replay-relative line numbers", function()
    local s = span({ "a", "b", "c" }, { "-- a", "-- b", "-- c" })
    local res = verify.texts(s, { { idiom = "subst-range", label = ":s", ex = "1,3s/^/-- /", cost = 10 } }, 200)
    assert.same({ true }, res)
  end)

  it("does not touch the user's registers", function()
    vim.fn.setreg('"', "keep")
    local s = span({ "one", "two" }, { "two" })
    assert.is_true(verify.text(s, { idiom = "count-dd", label = "dd", keys = "dd", cost = 2 }))
    assert.equals("keep", vim.fn.getreg('"'))
  end)
end)

describe("verify.cursor", function()
  it("checks a motion lands on the target and restores the view", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local from = vim.fn.winsaveview()
    vim.api.nvim_win_set_cursor(0, { 20, 2 })
    local win = vim.api.nvim_get_current_win()
    assert.is_true(verify.cursor(win, from, { idiom = "count-jk", label = "7j", keys = "7j", cost = 2 }, { 8, 0 }))
    assert.is_false(verify.cursor(win, from, { idiom = "count-jk", label = "6j", keys = "6j", cost = 2 }, { 8, 0 }))
    assert.same({ 20, 2 }, vim.api.nvim_win_get_cursor(0))
  end)
end)
