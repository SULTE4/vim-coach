local reports = {}
package.loaded["vim_coach.sink"] = {
  report = function(f)
    table.insert(reports, f)
    return true
  end,
  used = function() end,
}

local cost = require("vim_coach.cost")
local config = require("vim_coach.config")
local keys = require("vim_coach.keys")

local N = 20000

-- Representative normal-mode stream: runs, counts, operators, text objects, f/t.
local NORMAL = {
  "j", "j", "j", "j", "j", "j", "j", "w", "w", "w", "w", "3", "d", "d", "c", "i", "w", "f", "(", "x",
  "$", "k", "k", "k", "k", "5", "j", "y", "y", "p", "g", "g", "G", "d", "i", '"', "l", "l", "l", "l",
  "l", "l", "A",
}
local INSERT = {}
for ch in ("local function foo(bar) return bar + 1 end"):gmatch(".") do
  INSERT[#INSERT + 1] = ch
end
INSERT[#INSERT + 1] = "\128kb"
INSERT[#INSERT + 1] = "\23"

local function drive(list, count)
  local on_key = keys._on_key
  local n = #list
  local t0 = vim.uv.hrtime()
  for i = 1, count do
    local k = list[(i - 1) % n + 1]
    on_key(k, k)
  end
  return (vim.uv.hrtime() - t0) / 1e3 / count -- microseconds per key
end

describe("keys perf", function()
  before_each(function()
    config.setup({})
    reports = {}
    vim.cmd("enew!")
    local lines = {}
    for i = 1, 50 do
      lines[i] = ("    line %d text"):format(i)
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    keys.setup()
    keys._reset()
  end)

  after_each(function()
    keys.stop()
    vim.cmd("silent! bwipeout!")
  end)

  it("adds under perf_key_us per key over 20k keys", function()
    -- warm up the JIT and caches
    keys._set_mode("n")
    drive(NORMAL, 2000)
    keys._set_mode("i")
    drive(INSERT, 2000)

    keys._set_mode("n")
    local normal = drive(NORMAL, N)
    keys._set_mode("i")
    local insert = drive(INSERT, N)
    keys._set_mode("n")
    local mixed = (normal + insert) / 2
    print(("on_key per key: normal %.3f us, insert %.3f us, mixed %.3f us"):format(normal, insert, mixed))
    assert.is_true(mixed < cost.perf_key_us, "mixed " .. mixed)
    assert.is_true(normal < cost.perf_key_us, "normal " .. normal)
    assert.is_true(insert < cost.perf_key_us, "insert " .. insert)
    assert.is_true(keys.total() >= 2 * N)
  end)

  it("ignores untyped keys at almost no cost", function()
    local on_key = keys._on_key
    local t0 = vim.uv.hrtime()
    for _ = 1, N do
      on_key("j", "")
    end
    local us = (vim.uv.hrtime() - t0) / 1e3 / N
    assert.is_true(us < cost.perf_key_us, "untyped " .. us)
  end)

  it("analyzes one finished run in a couple of milliseconds", function()
    keys._set_mode("n")
    vim.wo.relativenumber = true -- counted j/k are only suggested with relative numbers
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    local captured = {}
    local orig = vim.schedule
    vim.schedule = function(f)
      captured[#captured + 1] = f
    end
    for _ = 1, 7 do
      keys._on_key("j", "j")
    end
    vim.api.nvim_win_set_cursor(0, { 8, 6 })
    keys._on_key("0", "0") -- a different command ends the run
    vim.schedule = orig
    assert.is_true(#captured >= 1)
    local t0 = vim.uv.hrtime()
    for _, f in ipairs(captured) do
      f()
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6
    print(("deferred analysis of one run: %.3f ms"):format(ms))
    assert.equals(1, #reports)
    assert.equals("count-jk", reports[1].event.idiom)
    assert.is_true(ms < 2, "analysis took " .. ms)
  end)
end)
