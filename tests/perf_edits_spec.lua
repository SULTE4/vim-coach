local cost = require("vim_coach.cost")

local reports = {}
package.loaded["vim_coach.sink"] = {
  report = function(f)
    table.insert(reports, f)
    return true
  end,
  used = function() end,
}
package.loaded["vim_coach.keys"] = {
  counters = function()
    return { total = 0, printable = 0, bs = 0, cw = 0, cu = 0, x = 0, dd = 0, arrows = 0, esc = 0 }
  end,
  total = function()
    return 0
  end,
}

local edits = require("vim_coach.edits")
local verify = require("vim_coach.verify")
local config = require("vim_coach.config")

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

-- Typed command line, so every edit is its own undo step like a real user's.
local function ex(cmd)
  vim.api.nvim_feedkeys(vim.keycode(":silent " .. cmd .. "<CR>"), "tx", false)
end

describe("edits performance", function()
  before_each(function()
    reports = {}
    config.setup({})
  end)
  after_each(function()
    edits.stop()
    verify.stop()
  end)

  it("finalizes a 50-line span including verify within the budget", function()
    verify.warm()
    local lines = {}
    for i = 1, 400 do
      lines[i] = "local value_" .. i .. " = compute(" .. i .. ")"
    end
    vim.cmd("enew!")
    vim.bo.shiftwidth = 2
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd("set nomodified")
    edits.setup()
    local buf = vim.api.nvim_get_current_buf()

    local times = {}
    for round = 1, 12 do
      -- 50 lines get a prefix; alternate add and remove so each round is a fresh edit
      local from = 100 + round
      ex(("%d,%ds/^/-- /"):format(from, from + 49))
      local t0 = now_ms()
      edits.flush(buf)
      times[#times + 1] = now_ms() - t0
      ex(("%d,%ds/^-- //"):format(from, from + 49))
      edits.flush(buf)
    end
    table.sort(times)
    local median = times[math.floor(#times / 2)]
    print(("finalize 50 lines: min %.2f ms, median %.2f ms, max %.2f ms"):format(times[1], median, times[#times]))
    assert.is_true(#reports >= 1, "expected findings from the edits")
    assert.is_true(median < cost.perf_span_ms, ("median %.2f ms"):format(median))
  end)

  it("keeps the on_bytes callback tiny", function()
    local n = 20000
    local function run(attached)
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("a", 80), "second" })
      vim.cmd("set nomodified")
      local buf = vim.api.nvim_get_current_buf()
      if attached then
        edits.setup()
        assert.is_true(edits.attach(buf))
      end
      local t0 = vim.uv.hrtime()
      for i = 1, n do
        vim.api.nvim_buf_set_text(buf, 0, i % 80, 0, i % 80, { "x" })
      end
      local per_us = (vim.uv.hrtime() - t0) / 1e3 / n
      edits.stop()
      return per_us
    end
    run(false) -- warm up
    local base = run(false)
    local with = run(true)
    local overhead = with - base
    print(("on_bytes overhead: %.2f us per change (base %.2f us)"):format(overhead, base))
    assert.is_true(overhead < 3, ("overhead %.2f us"):format(overhead))
  end)

  it("does not read buffer text or run analysis inside on_bytes", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc", "def" })
    edits.setup()
    local buf = vim.api.nvim_get_current_buf()
    local orig = vim.api.nvim_buf_get_lines
    local calls = 0
    vim.api.nvim_buf_get_lines = function(...)
      calls = calls + 1
      return orig(...)
    end
    for i = 1, 100 do
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "x" })
    end
    vim.api.nvim_buf_get_lines = orig
    assert.equals(0, calls)
    assert.equals(0, #reports)
  end)
end)
