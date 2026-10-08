local reports, used = {}, {}
package.loaded["vim_coach.sink"] = {
  report = function(f)
    table.insert(reports, f)
    return true
  end,
  used = function(id)
    table.insert(used, id)
  end,
}

local cost = require("vim_coach.cost")
local config = require("vim_coach.config")
local keys = require("vim_coach.keys")

local function feed(s)
  vim.api.nvim_feedkeys(vim.keycode(s), "tx", false)
end

local function wait_for(pred)
  vim.wait(cost.run_idle_ms + 400, pred, 10)
end

local function lines_fixture(n)
  local t = {}
  for i = 1, n do
    t[i] = ("    line %d text"):format(i)
  end
  return t
end

local function scratch(lines, cursor, relnum)
  vim.cmd("enew!")
  vim.bo.buftype = ""
  vim.wo.relativenumber = relnum ~= false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
end

describe("keys", function()
  before_each(function()
    config.setup({})
    reports, used = {}, {}
    vim.o.scrolloff = 0
    keys.setup()
    keys._reset()
    keys._set_mode("n")
  end)

  after_each(function()
    keys.stop()
    vim.cmd("silent! bwipeout!")
  end)

  it("reports 7j as count-jk for a run of j", function()
    scratch(lines_fixture(40), { 1, 6 })
    feed("jjjjjjj")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    local f = reports[1]
    assert.equals("count-jk", f.event.idiom)
    assert.equals(7, f.event.naive)
    assert.equals(2, f.event.ideal)
    assert.equals("keys", f.event.src)
    assert.is_true(f.event.measured)
    assert.equals("7j", f.label)
    assert.equals("j x7", f.was)
    assert.same({ 8, 6 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("prefers } when a blank line is the target", function()
    local l = lines_fixture(40)
    l[9] = ""
    scratch(l, { 1, 0 })
    feed("jjjjjjjj")
    wait_for(function() return #reports > 0 end)
    assert.equals("paragraph-jump", reports[1].event.idiom)
    assert.equals(1, reports[1].event.ideal)
    assert.is_true(vim.tbl_contains(reports[1].event.alts, "count-jk"))
  end)

  it("ends a run when another command arrives", function()
    scratch(lines_fixture(40), { 1, 6 })
    feed("jjjjjjj0")
    wait_for(function() return #reports > 0 end)
    assert.equals("count-jk", reports[1].event.idiom)
    assert.same({ 8, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("keeps a vertical run followed by an edit", function()
    scratch(lines_fixture(40), { 1, 6 })
    feed("jjjjjjjdd")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    assert.equals("count-jk", reports[1].event.idiom)
    assert.equals(7, reports[1].event.naive)
    assert.equals("7j", reports[1].label)
  end)

  it("keeps a horizontal run followed by an edit", function()
    scratch({ "foo(bar, baz)" }, { 1, 0 })
    feed("llllllx")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    assert.equals("find-char", reports[1].event.idiom)
    assert.equals("fr", reports[1].label)
    assert.equals(6, reports[1].event.naive)
  end)

  it("keeps a w run followed by an edit", function()
    scratch({ "a b c d e f g" }, { 1, 0 })
    feed("wwwwx")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    assert.equals(4, reports[1].event.naive)
  end)

  it("drops an edited vertical run over a closed fold", function()
    scratch(lines_fixture(40), { 1, 6 })
    vim.wo.foldmethod = "manual"
    vim.cmd("3,5fold")
    vim.cmd("normal! gg")
    feed("jjjjjjjdd")
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("reports jkjkjkjk as a fidget", function()
    scratch(lines_fixture(40), { 10, 6 })
    feed("jkjkjkjk")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    local e = reports[1].event
    assert.equals("fidget", e.idiom)
    assert.equals(8, e.naive)
    assert.equals(0, e.ideal)
    assert.equals("jk", reports[1].label)
    assert.equals("j/k x8, net 0", reports[1].was)
  end)

  it("reports jjkkjjkk as a fidget", function()
    scratch(lines_fixture(40), { 10, 6 })
    feed("jjkkjjkk")
    wait_for(function() return #reports > 0 end)
    assert.equals("fidget", reports[1].event.idiom)
  end)

  it("ignores a short jkjk", function()
    scratch(lines_fixture(40), { 10, 6 })
    feed("jkjk")
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("charges an overshoot with all presses", function()
    scratch(lines_fixture(40), { 1, 6 })
    feed("jjjjjjjkk")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    local e = reports[1].event
    assert.equals("count-jk", e.idiom)
    assert.equals(9, e.naive)
    assert.equals(2, e.ideal)
    assert.equals("5j", reports[1].label)
    assert.equals("j x7, k x2", reports[1].was)
  end)

  it("verifies a horizontal overshoot", function()
    scratch({ "foo(bar, baz)" }, { 1, 0 })
    feed("llllllhh")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    assert.equals("find-char", reports[1].event.idiom)
    assert.equals("fb", reports[1].label)
    assert.equals(8, reports[1].event.naive)
    assert.equals("l x6, h x2", reports[1].was)
  end)

  it("reports find-char for a run of l", function()
    scratch({ "foo(bar, baz)" }, { 1, 0 })
    feed("llllll")
    wait_for(function() return #reports > 0 end)
    assert.equals("find-char", reports[1].event.idiom)
    assert.equals("fr", reports[1].label)
    assert.equals(6, reports[1].event.naive)
  end)

  it("reports word-motion for a run of w", function()
    scratch({ "a b c d e f g" }, { 1, 0 })
    feed("wwww")
    wait_for(function() return #reports > 0 end)
    assert.equals(1, #reports)
    assert.is_true(reports[1].event.idiom == "word-motion" or reports[1].event.idiom == "find-char")
    assert.equals(4, reports[1].event.naive)
  end)

  it("treats arrow keys in normal mode like hjkl", function()
    scratch(lines_fixture(40), { 1, 6 })
    feed("<Down><Down><Down>")
    wait_for(function() return #reports > 0 end)
    assert.equals("count-jk", reports[1].event.idiom)
    assert.equals("<Down> x3", reports[1].was)
    assert.equals(3, reports[1].event.naive)
  end)

  it("ignores runs below the threshold", function()
    scratch(lines_fixture(40), { 1, 0 })
    feed("jjj")
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("drops a run when the buffer changed", function()
    scratch(lines_fixture(40), { 1, 0 })
    feed("jjjjjjj")
    vim.api.nvim_buf_set_lines(0, 30, 31, false, { "changed" })
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("drops runs in excluded buffers", function()
    scratch(lines_fixture(40), { 1, 0 })
    vim.bo.filetype = "help"
    feed("jjjjjjj")
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("substitutes $a with A", function()
    scratch({ "hello" }, { 1, 0 })
    feed("$aXYZ<Esc>")
    wait_for(function() return #reports > 0 end)
    assert.equals("append-eol", reports[1].event.idiom)
    assert.equals(2, reports[1].event.naive)
    assert.equals(1, reports[1].event.ideal)
    assert.equals("A", reports[1].label)
  end)

  it("substitutes ^i, d$, c$, y$ and xi", function()
    scratch({ "  hello world" }, { 1, 5 })
    feed("^i<Esc>")
    wait_for(function() return #reports >= 1 end)
    feed("y$")
    wait_for(function() return #reports >= 2 end)
    feed("d$")
    wait_for(function() return #reports >= 3 end)
    feed("ixy<Esc>")
    feed("xi<Esc>")
    wait_for(function() return #reports >= 4 end)
    feed("c$<Esc>")
    wait_for(function() return #reports >= 5 end)
    local ids = {}
    for _, r in ipairs(reports) do
      ids[#ids + 1] = r.event.idiom
    end
    assert.same({ "insert-bol", "yank-eol", "delete-eol", "substitute-char", "change-eol" }, ids)
  end)

  it("does not substitute counted or separated sequences", function()
    scratch({ "hello world" }, { 1, 0 })
    feed("$2a<Esc>")
    feed("$ja<Esc>")
    vim.wait(250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("marks adoption for a counted motion", function()
    scratch(lines_fixture(40), { 1, 0 })
    feed("5j")
    wait_for(function() return vim.tbl_contains(used, "count-jk") end)
    assert.is_true(vim.tbl_contains(used, "count-jk"))
    assert.equals(0, #reports)
  end)

  it("marks adoption for text objects and special keys", function()
    scratch({ 'x = "hello"' }, { 1, 6 })
    feed('ci"bye<Esc>')
    feed("<C-d>")
    feed("gg")
    wait_for(function() return vim.tbl_contains(used, "half-page") end)
    assert.is_true(vim.tbl_contains(used, "ci-quote"))
    assert.is_true(vim.tbl_contains(used, "half-page"))
    assert.is_true(vim.tbl_contains(used, "goto-line"))
  end)

  it("tokenizes counts, registers, operators and text objects", function()
    scratch({ "foo (bar) baz", "second line", "third line", "fourth" }, { 1, 0 })
    vim.bo.commentstring = "# %s"
    feed('3j"ayyfbdwgUiwd2jdd>>gcc')
    local ring = keys._ring()
    assert.same({ "3j", '"ayy', "fb", "dw", "gUiw", "d2j", "dd", ">>", "gcc" }, ring)
  end)

  it("never stores insert-mode text", function()
    scratch({ "hello" }, { 1, 0 })
    feed("Asecret password<BS><C-w>zzz<Esc>")
    local ring = keys._ring()
    assert.same({ "A" }, ring)
    feed(":s/hello/hidden/<CR>")
    feed("ihidden2<Esc>")
    for _, tok in ipairs(keys._ring()) do
      assert.is_nil(tok:find("hidden", 1, true))
      assert.is_nil(tok:find("secret", 1, true))
    end
  end)

  it("redacts the character of r", function()
    scratch({ "hello" }, { 1, 0 })
    feed("rz")
    assert.same({ "r_" }, keys._ring())
  end)

  it("keeps counter semantics", function()
    scratch({ "hello world", "second", "third", "fourth", "fifth" }, { 1, 0 })
    local c0 = keys.counters()
    assert.equals(0, c0.total)
    feed("xx")
    feed("3x")
    feed("dd")
    feed("2dd")
    assert.same({ total = 9, printable = 0, bs = 0, cw = 0, cu = 0, x = 2, dd = 1, arrows = 0, esc = 0 },
      vim.tbl_extend("force", keys.counters(), {}))
    feed("ihello<BS><C-w><C-u>x<Left><Esc>")
    local c = keys.counters()
    -- i hello <BS> <C-w> <C-u> x <Left> <Esc> = 12 keys
    assert.equals(21, c.total)
    assert.equals(6, c.printable)
    assert.equals(1, c.bs)
    assert.equals(1, c.cw)
    assert.equals(1, c.cu)
    assert.equals(1, c.arrows)
    assert.equals(1, c.esc)
    assert.equals(c.total, keys.total())
    -- counters() returns a copy
    c.total = 0
    assert.equals(21, keys.total())
  end)

  it("counts arrows in normal mode and ignores cmdline text", function()
    scratch({ "a", "b", "c" }, { 1, 0 })
    feed("<Down><Up>")
    assert.equals(2, keys.counters().arrows)
    local before = keys.counters().printable
    feed(":echo 1<CR>")
    assert.equals(before, keys.counters().printable)
    assert.equals(2 + 8, keys.total())
  end)

  it("ignores keys that did not come from the user and keys during verify", function()
    keys._on_key("j", "")
    assert.equals(0, keys.total())
    local verify = require("vim_coach.verify")
    verify.busy = true
    keys._on_key("j", "j")
    verify.busy = false
    assert.equals(0, keys.total())
    keys._on_key("j", "j")
    assert.equals(1, keys.total())
  end)

  it("pauses detection while recording", function()
    scratch(lines_fixture(40), { 1, 0 })
    feed("qa")
    feed("jjjjjjj")
    feed("q")
    vim.wait(cost.run_idle_ms + 250, function() return #reports > 0 end, 10)
    assert.equals(0, #reports)
  end)

  it("stops cleanly", function()
    keys.stop()
    local t = keys.total()
    scratch({ "a" }, { 1, 0 })
    feed("jjjj")
    assert.equals(t, keys.total())
  end)

  describe("relativenumber", function()
    it("does not suggest counted j/k without relativenumber", function()
      scratch(lines_fixture(40), { 1, 6 }, false)
      feed("jjjjjjj")
      wait_for(function() return #reports > 0 end)
      for _, f in ipairs(reports) do
        assert.are_not.equals("count-jk", f.event.idiom)
        assert.is_false(vim.tbl_contains(f.event.alts, "count-jk"))
      end
    end)

    it("reports nothing for a run followed by an edit without relativenumber", function()
      scratch(lines_fixture(40), { 1, 6 }, false)
      feed("jjjjjjjdd")
      vim.wait(cost.run_idle_ms + 400, function() return false end, 10)
      assert.equals(0, #reports)
    end)

    it("suggests counted j/k anyway with count_jk = always", function()
      config.setup({ count_jk = "always" })
      scratch(lines_fixture(40), { 1, 6 }, false)
      feed("jjjjjjj")
      wait_for(function() return #reports > 0 end)
      assert.equals("count-jk", reports[1].event.idiom)
      assert.equals("7j", reports[1].label)
    end)
  end)
end)
