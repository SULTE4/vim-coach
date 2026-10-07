local scan = require("vim_coach.scan")

local function run_on(lines)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.fn.setqflist({}, "r")
  scan.run(0)
  return vim.fn.getqflist({ all = 1 })
end

describe("scan", function()
  it("finds runs of near-identical lines", function()
    local lines = { "local a = 1" }
    for i = 1, 8 do
      lines[#lines + 1] = ("  items[%d] = foo(\"name%d\", %d)"):format(i, i, i * 10)
    end
    lines[#lines + 1] = "return a"
    local qf = run_on(lines)
    assert.same("vim-coach scan", qf.title)
    assert.same(1, #qf.items)
    assert.same(2, qf.items[1].lnum)
    assert.truthy(qf.items[1].text:find("8 similar lines", 1, true))
    vim.cmd("cclose")
  end)

  it("finds shared prefixes", function()
    local qf = run_on({ "x", "import alpha", "import beta", "import gamma", "y" })
    assert.same(1, #qf.items)
    assert.same(2, qf.items[1].lnum)
    vim.cmd("cclose")
  end)

  it("reports nothing for varied text", function()
    local msg
    local orig = vim.notify
    vim.notify = function(m) msg = m end
    local qf = run_on({ "one", "two words", "completely different", "end." })
    vim.notify = orig
    assert.same(0, #qf.items)
    assert.truthy(msg:find("no repeated structures found", 1, true))
  end)

  it("is fast on 10k lines", function()
    local lines = {}
    for i = 1, 10000 do
      lines[i] = ("value_%d = %d"):format(i % 7, i)
    end
    local t = vim.uv.hrtime()
    scan.find_runs(lines)
    assert.is_true((vim.uv.hrtime() - t) / 1e6 < 200)
  end)
end)
