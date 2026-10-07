-- Static idiom catalog (design doc 5.3). Ships with the plugin, never written to disk.
--
-- Fields:
--   category    group shown in :VimCoach stats
--   difficulty  1 (trivial) to 5 (hard to learn)
--   requires    prerequisite idiom IDs (concept entries below make these resolve)
--   keys        typical ideal cost in keystrokes
--   desc        one-line description for the stats window
--   example     short key notation shown to the user
--   adopt       Lua patterns matched against tokenized normal-mode commands in
--               keytrans notation (e.g. "7j", "ci\"", "<C-D>"). When the user types
--               a matching command, it counts toward adoption. nil = not observable.
--   concept     true for prerequisite-only entries that are never detected
--   stats_only  true for habits that are tracked in stats but never hinted or recommended

local C = {}

-- Prerequisite concepts -------------------------------------------------------

C["counts"] = { category = "concepts", difficulty = 1, requires = {}, keys = 1, concept = true,
  desc = "Prefix a command with a count", example = "5j" }
C["operators"] = { category = "concepts", difficulty = 1, requires = {}, keys = 1, concept = true,
  desc = "Operator + motion grammar (d, c, y, >, <)", example = "dw" }
C["text-objects"] = { category = "concepts", difficulty = 2, requires = { "operators" }, keys = 1, concept = true,
  desc = "i/a text objects after an operator", example = "diw" }
C["visual-mode"] = { category = "concepts", difficulty = 1, requires = {}, keys = 1, concept = true,
  desc = "Visual, line and block selections", example = "V" }
C["registers"] = { category = "concepts", difficulty = 3, requires = {}, keys = 2, concept = true,
  desc = "Named registers", example = "\"ay" }
C["regex"] = { category = "concepts", difficulty = 4, requires = {}, keys = 1, concept = true,
  desc = "Vim regular expressions", example = "\\v(\\w+)" }
C["ex-ranges"] = { category = "concepts", difficulty = 2, requires = {}, keys = 1, concept = true,
  desc = "Line ranges for Ex commands", example = ":2,8" }

-- Motions ---------------------------------------------------------------------

C["count-jk"] = { category = "motions", difficulty = 1, requires = { "counts" }, keys = 2,
  desc = "Count before j/k instead of repeating it", example = "7j",
  adopt = { "^%d+[jk]$" } }
C["paragraph-jump"] = { category = "motions", difficulty = 1, requires = {}, keys = 1,
  desc = "Jump to the next or previous blank line", example = "}",
  adopt = { "^%d*[{}]$" } }
C["screen-jump"] = { category = "motions", difficulty = 2, requires = {}, keys = 1,
  desc = "Jump to top, middle or bottom of the screen", example = "H M L",
  adopt = { "^[HML]$" } }
C["goto-line"] = { category = "motions", difficulty = 2, requires = {}, keys = 3,
  desc = "Jump to a line number, first or last line", example = "42G gg G",
  adopt = { "^%d*G$", "^gg$" } }
C["half-page"] = { category = "motions", difficulty = 1, requires = {}, keys = 1,
  desc = "Scroll half a page", example = "<C-d> <C-u>",
  adopt = { "^<C%-[DU]>$" } }
C["find-char"] = { category = "motions", difficulty = 2, requires = {}, keys = 2,
  desc = "Jump to or before a character on the line", example = "f( t,",
  adopt = { "^%d*[fFtT].$" } }
C["word-motion"] = { category = "motions", difficulty = 1, requires = {}, keys = 1,
  desc = "Move by words instead of characters", example = "w b e",
  adopt = { "^%d+[wbeWBE]$" } }
C["line-ends"] = { category = "motions", difficulty = 1, requires = {}, keys = 1,
  desc = "Jump to start, first non-blank or end of line", example = "0 ^ $",
  adopt = { "^[0%^%$]$" } }
C["fidget"] = { category = "habits", difficulty = 1, requires = {}, keys = 0, stats_only = true,
  desc = "Back-and-forth movement that goes nowhere (jkjk, hlhl)", example = "jkjk" }
C["hjkl"] = { category = "habits", difficulty = 1, requires = {}, keys = 1,
  desc = "Home-row hjkl instead of arrow keys", example = "hjkl" }

-- Text objects ----------------------------------------------------------------

C["ci-quote"] = { category = "text-objects", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Change inside quotes", example = "ci\"",
  adopt = { "^%d*[cdy]i[\"'`]$" } }
C["ci-bracket"] = { category = "text-objects", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Change inside (), [], {} or <>", example = "ci(",
  adopt = { "^%d*[cdy]i[%(%)%[%]{}<>bB]$" } }
C["ci-tag"] = { category = "text-objects", difficulty = 3, requires = { "text-objects" }, keys = 3,
  desc = "Change inside an XML/HTML tag", example = "cit",
  adopt = { "^%d*[cdy]it$" } }
C["ciw"] = { category = "text-objects", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Change the word under the cursor", example = "ciw",
  adopt = { "^%d*ci[wW]$", "^%d*c[weWE]$" } }
C["diw"] = { category = "text-objects", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Delete a word (diw, daw, dw, de)", example = "daw",
  adopt = { "^%d*d[ia][wW]$", "^%d*d[weWE]$" } }
C["dt-char"] = { category = "text-objects", difficulty = 3, requires = { "find-char", "operators" }, keys = 3,
  desc = "Delete or change up to a character", example = "dt) cf,",
  adopt = { "^%d*[dc][tTfF].$" } }
C["cc-line"] = { category = "text-objects", difficulty = 1, requires = {}, keys = 2,
  desc = "Change the whole line", example = "cc S",
  adopt = { "^%d*cc$", "^S$" } }

-- Operators -------------------------------------------------------------------

C["count-x"] = { category = "operators", difficulty = 1, requires = { "counts" }, keys = 2,
  desc = "Count before x instead of repeating it", example = "5x",
  adopt = { "^%d+x$" } }
C["count-dd"] = { category = "operators", difficulty = 1, requires = { "counts" }, keys = 3,
  desc = "Count before dd instead of repeating it", example = "3dd",
  adopt = { "^%d+dd$", "^d%d+[jk]$" } }
C["delete-eol"] = { category = "operators", difficulty = 1, requires = {}, keys = 1,
  desc = "D deletes to end of line", example = "D",
  adopt = { "^D$" } }
C["change-eol"] = { category = "operators", difficulty = 1, requires = {}, keys = 1,
  desc = "C changes to end of line", example = "C",
  adopt = { "^C$" } }
C["yank-eol"] = { category = "operators", difficulty = 1, requires = {}, keys = 1,
  desc = "Y yanks to end of line", example = "Y",
  adopt = { "^Y$" } }
C["indent-block"] = { category = "operators", difficulty = 2, requires = { "text-objects" }, keys = 3,
  desc = "Indent or reindent a block at once", example = ">ip =i{",
  adopt = { "^%d*[<>=][ia][pB{}]$", "^%d*[<>=][<>=]$" } }
C["join-lines"] = { category = "operators", difficulty = 1, requires = {}, keys = 1,
  desc = "Join lines with J", example = "J 3J",
  adopt = { "^%d*g?J$" } }
C["case-change"] = { category = "operators", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Change case with ~, gU, gu", example = "gUiw ~",
  adopt = { "^%d*~$", "^%d*g[uU~].+$" } }
C["comment-gc"] = { category = "operators", difficulty = 2, requires = { "operators" }, keys = 3,
  desc = "Toggle comments with gc", example = "gcc gcip",
  adopt = { "^%d*gc.+$" } }

-- Insert-mode entry and editing -----------------------------------------------

C["append-eol"] = { category = "insert", difficulty = 1, requires = {}, keys = 1,
  desc = "A appends at end of line (instead of $a)", example = "A",
  adopt = { "^A$" } }
C["insert-bol"] = { category = "insert", difficulty = 1, requires = {}, keys = 1,
  desc = "I inserts at first non-blank (instead of ^i)", example = "I",
  adopt = { "^I$" } }
C["substitute-char"] = { category = "insert", difficulty = 1, requires = {}, keys = 1,
  desc = "s replaces a character (instead of xi)", example = "s",
  adopt = { "^%d*s$" } }
C["insert-ctrl-w"] = { category = "insert", difficulty = 2, requires = {}, keys = 1,
  desc = "<C-w> in insert mode deletes the word before the cursor", example = "<C-w>" }
C["insert-ctrl-u"] = { category = "insert", difficulty = 2, requires = {}, keys = 1,
  desc = "<C-u> in insert mode deletes back to the start of the line", example = "<C-u>" }

-- Visual and bulk edits -------------------------------------------------------

C["visual-block"] = { category = "visual", difficulty = 3, requires = { "visual-mode" }, keys = 6,
  desc = "Visual block insert/append on many lines", example = "<C-v>jjI",
  adopt = { "^<C%-V>$" } }
C["normal-range"] = { category = "ex", difficulty = 3, requires = { "ex-ranges" }, keys = 10,
  desc = ":normal runs the same keys on many lines", example = ":'<,'>norm A;" }
C["subst-range"] = { category = "ex", difficulty = 3, requires = { "ex-ranges", "regex" }, keys = 10,
  desc = ":s over a range of lines", example = ":%s/old/new/g" }
C["global-cmd"] = { category = "ex", difficulty = 5, requires = { "regex" }, keys = 12,
  desc = ":g runs a command on matching lines", example = ":g/TODO/d" }
C["move-lines"] = { category = "ex", difficulty = 2, requires = {}, keys = 4,
  desc = "Move lines with :m or ddp", example = ":m +1 ddp",
  adopt = { "^ddp$", "^ddP$" } }
C["dup-lines"] = { category = "ex", difficulty = 1, requires = {}, keys = 3,
  desc = "Duplicate lines with yyp or :t", example = "yyp :t.",
  adopt = { "^yyp$", "^yyP$" } }

-- Repetition ------------------------------------------------------------------

C["dot-repeat"] = { category = "macros", difficulty = 1, requires = {}, keys = 1,
  desc = "Repeat the last change with .", example = ".",
  adopt = { "^%d*%.$" } }
C["macro"] = { category = "macros", difficulty = 4, requires = { "registers" }, keys = 6,
  desc = "Record and replay a macro", example = "qa...q @a",
  adopt = { "^%d*@.$" } }

return C
