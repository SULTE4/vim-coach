# vim-coach

A Neovim plugin that watches how you move and edit, notices when a Vim idiom would have done the same thing in fewer keystrokes, pops up when you keep repeating the same inefficient action, and ranks which idioms are most worth learning next.

```
        jjjjjjj|
        ╭─ vim-coach ──────────────────╮
        │ j x7 - 3rd time this session │
        │ Try: 7j   (saves 5 keys)     │
        │ also: }  G                   │
        ╰──────────────────────────────╯
```

Every suggestion is **verified**: the candidate idiom is replayed on the text as it was before your edit, and it is only reported if it produces exactly the same result.

## What it catches

**How you move** (keystroke analysis via `vim.on_key`):

| You typed | It suggests |
| --- | --- |
| `jjjjjjj` | `7j`, `}`, `G` (whichever verifies and is cheapest) |
| `jjjjjjjkk` (overshoot, then correct) | `5j`, counting all 9 presses |
| `llllll` / `wwww` | `f(`, `t,`, `3w`, `$` |
| `$a`, `^i`, `xi` | `A`, `I`, `s` |
| `d$`, `c$`, `y$` | `D`, `C`, `Y` |
| `jkjkjkjk` (back and forth, going nowhere) | nothing to learn: tracked as a "fidget" habit in stats, never hinted |

**What you changed** (edit-shape analysis via text diffs):

| Edit shape | Idioms |
| --- | --- |
| String or bracket contents replaced | `ci"`, `ci(`, `cit`, ... |
| Word / line tail / whole line changed | `ciw`, `C`, `D`, `cc`, `dt,` |
| `xxxxx`, `dd dd dd`, many `<BS>` | `dw`, `3dd`, `<C-w>`, `<C-u>` |
| Same prefix/suffix added on many lines | visual block `<C-v>..I`, `:normal`, `:s/^/` |
| Same substitution on many lines | `:s`, `:g` |
| Lines moved / duplicated / joined | `:m`, `ddp`, `yyp`, `:t.`, `J` |
| Block indented, case changed, commented | `>ip`, `gUiw`, `gcc` |
| The same edit repeated 3+ times | `.` |

## Requirements

- Neovim 0.10 or newer (developed and tested on 0.13-dev). Classic Vim is not supported.
- No dependencies. [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) is only needed to run the tests.

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "SULTE4/vim-coach", main = "vim_coach", event = "VeryLazy", opts = {} }
```

Any other plugin manager: add the repo and call `require("vim_coach").setup({})`.

## Usage

Just edit as usual. When you repeat the same inefficient action, a popup suggests the better idiom (see [Popups](#popups)). Open the stats any time:

| Command | What it does |
| --- | --- |
| `:VimCoach` / `:VimCoach stats` | Next idiom to learn, counts and keys saved per category, trend vs last week |
| `:VimCoach log` | Suggestions found this session |
| `:VimCoach scan` | Find runs of similar lines in the current buffer (quickfix list) |
| `:VimCoach dismiss {id}` | Stop hinting and recommending an idiom (`undismiss` to undo) |
| `:VimCoach learned {id}` | Mark an idiom as learned |
| `:VimCoach toggle` | Turn the detectors on or off |
| `:VimCoach reset` | Erase all stored stats (asks first) |

In the stats window: `q` close, `d` dismiss, `u` undismiss, `L` mark learned, `e` show this session's before/after example for the idiom under the cursor.

## Popups

A popup appears when you **repeat the same inefficient action**:

- **Escalating schedule**: on the 3rd time the same pattern (idiom) is seen in a session, then the 6th, 12th, 24th... A habit that persists keeps getting flagged, but less and less often.
- **Big wins right away**: a single edit that could have saved 20+ keys pops up on the first sighting.
- **Never in your way**: the popup does not take focus or keystrokes, closes after 5 s or when you enter insert mode, and at least 10 s pass between two popups. Nothing is shown in insert mode.
- **Stops when it should**: idioms you have learned (typed yourself 5 times across 2 days) or dismissed are never shown again. Stats-only habits such as fidgeting are never shown.

Position, via `popup.position`:

| Value | Where |
| --- | --- |
| `"cursor"` (default) | right below the cursor, flipping above it near the bottom of the window |
| `"top_right"` | the top-right corner of the editor |

Prefer something quieter? Set `hint = "virt"` (end-of-line virtual text), `"notify"` (`vim.notify`) or `false`. The same schedule applies to every style.

Highlight groups (default-linked, override them in your colorscheme): `VimCoachPopup` (NormalFloat), `VimCoachPopupBorder` (FloatBorder), `VimCoachPopupKey` (DiagnosticHint, the suggested keys), `VimCoachHint` (DiagnosticHint, virtual-text style).

## How it decides what to learn
- **Learning value** = keys you could have saved (older events decay with a 14-day half-life) / how hard the idiom is to learn (1 to 5). Frequent, cheap wins rank first.
- **Prerequisites**: if the top idiom needs another one you have not learned (e.g. `dt,` needs `f`/`t`), the prerequisite is recommended first.
- **Adoption**: when you start typing an idiom yourself (5 times across 2 days), it is marked learned automatically.

Savings are estimates from observed keys and modeled edits, not exact measurements.

## Configuration

Defaults:

```lua
require("vim_coach").setup({
  enabled = true,
  hint = "popup", -- "popup" | "virt" (end-of-line virtual text) | "notify" | false
  popup = { position = "cursor" }, -- "cursor" | "top_right"
  detectors = { keys = true, edits = true },
  exclude_ft = { "help", "qf", "netrw", "neo-tree", "NvimTree", "TelescopePrompt",
                 "lazy", "mason", "gitcommit", "vim_coach" },
  data_path = nil, -- nil = stdpath("data") .. "/vim_coach.json"
})
```

Popup knobs in `cost.lua`: `hint_after` (3), `hint_escalation` (2), `hint_big_saving` (20), `hint_cooldown_s` (10), `popup_ttl_ms` (5000).

Every threshold, cooldown, timing and budget lives in [`lua/vim_coach/cost.lua`](lua/vim_coach/cost.lua), so tuning happens in one place.

## Privacy

- Only idiom ids and numbers (timestamps, filetype, line and key counts) are written to `stdpath("data")/vim_coach.json`. Code text is never written to disk.
- Characters typed in insert and command-line mode are never stored, only counted.
- Before/after examples shown with `e` stay in memory for the current session.

## Performance

The plugin is built not to lag:

- The keystroke hook is O(1) and allocation-free (about 0.5 us per key); the buffer-change hook only widens a dirty range and never reads text.
- All analysis waits until you pause (idle timer or leaving insert mode).
- Verification is capped (8 candidates, 4 ms per edit) and runs in a child `nvim --embed` process, so your registers, undo tree and `.` repeat are never touched. A 50-line edit is analyzed in about 3 ms.
- Large buffers (10k+ lines) and huge edits are skipped; detection pauses during macros.
- Stats are saved asynchronously, debounced and atomically, and merged safely across several running Neovim instances.

## Development

```
lua/vim_coach/
  keys.lua, motions.lua         keystroke analysis (runs, bursts, fidgets, sequences)
  edits.lua, diff.lua,
  candidates.lua                edit-shape analysis
  verify.lua                    replay in a child nvim / real window
  sink.lua, session.lua         dedupe, persistence and hints entry point
  store.lua, score.lua          JSON storage, decay and ranking
  hints.lua, stats.lua, scan.lua
  catalog.lua                   idiom catalog (category, difficulty, prerequisites)
  cost.lua                      every tunable number
```

```sh
make test                                  # whole suite
make test-file FILE=tests/keys_spec.lua    # one spec
```

Tests use plenary.nvim from `stdpath("data")/lazy/plenary.nvim`; set `PLENARY_DIR` to use another path. The suite includes performance gates for the keystroke and edit hooks.

Roadmap: move the engine into a Go language server so the same coach can run in VS Code and Zed.
