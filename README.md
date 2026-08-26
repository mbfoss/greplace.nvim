# greplace.nvim

> WORK IN PROGRESS

Project-wide search and replace by editing the grep results.

```
:Greplace <query>
```

greps the working tree and collects every matching line into a split named
`greplace://replace`. Each line is the matched line itself — plain, editable
text. The `file:line` shown in front of it is *virtual*: it is not part of the
line, it cannot be typed over, and it is what tells the plugin where the line
came from.

Edit the lines however you like — `:%s/…`, visual block, macros, by hand — and
write the buffer:

```
:w
```

Every changed line is written back to its source **in memory**: files already
open keep their buffer, files that are not open are loaded into one. Nothing is
written to disk, so the whole change is one `:wa` away — or one `u` per buffer
from being undone.

> **Requires Neovim ≥ 0.11** and [ripgrep](https://github.com/BurntSushi/ripgrep)
> on `$PATH`. No plugin dependencies.

## Installation

**lazy.nvim**

```lua
{
  "mbfoss/greplace.nvim",
  config = function()
    require("greplace").setup()
  end,
}
```

`setup()` is optional; the `:Greplace` and `:GreplaceEx` commands register
themselves, and nothing under `lua/greplace/` is loaded until one is first run.

## Usage

| Command | Effect |
| --- | --- |
| `:Greplace foo bar` | literal search for `foo bar` (smart-case) |
| `:Greplace` | with no query: re-run the last one, discarding unapplied edits |

Everything after `:Greplace` is the query, verbatim — spaces, quotes,
backslashes and leading dashes included, and it is always searched literally.
A regex, a case rule or a narrowed file set is asked for through `:GreplaceEx`
below.

### `:GreplaceEx` — searching with flags

`:GreplaceEx` is the same search with the file set and the match rules opened
up. Flags come first, then a bare `--`, then the query:

```
:GreplaceEx --filter *.lua --filter !*_spec.lua --hidden -- handle_event
:GreplaceEx --type md --dir docs -- TODO
:GreplaceEx --regex --word -- ^fn\s+\w+
```

Flags are written `--switch`, `--key value` or `--key=value`, and are split by
Vim's own rules (`:h <f-args>`): unescaped whitespace separates them, and a
backslash escapes the character after it, so a value containing a space is
written `--dir my\ src`. Quotes are not special. A repeatable flag is repeated
rather than given a list.

The `--` is what keeps the query verbatim: nothing after the first bare one is
parsed, so a query may hold spaces, quotes, leading dashes and another `--`. A
line without it is an error rather than a guess at where the flags stopped;
with no arguments at all, `:GreplaceEx` re-runs the last search like
`:Greplace`. Anything else that is wrong with the line — an unknown flag, a
value flag left without one — is reported instead of searched.

Flag names and values tab-complete: `--type` against `rg --type-list`, `--dir`
against directories, whether the value is written after the flag or glued to it
with `=`. A switch already on the line drops out of the candidates, and past
the `--` nothing completes at all — those words are a query, not a list.

| Flag | Effect |
| --- | --- |
| `--dir <path>` | search root (default: the working directory) |
| `--filter <glob>` | glob filter, repeatable: `*.txt`, `!*.lua`, `**/dir/**` |
| `--type <name>` | rg file type, repeatable: `lua`, `rust`, `!md` (see `rg --type-list`) |
| `--max-depth <n>` | maximum directory depth to descend |
| `--regex` | treat the query as a regex |
| `--case` / `--nocase` | case-sensitive / -insensitive (default: smart case) |
| `--word` / `--line` | match whole words / whole lines only |
| `--invert` | collect the lines that do *not* match |
| `--hidden` | include hidden files (dotfiles) |
| `--no-ignore` | ignore `.gitignore` / `.ignore` rules |
| `--follow` | follow symlinks |

There is no passthrough of raw ripgrep arguments, by design: the panel's whole
contract is that a shown line is the source line byte for byte, and `--replace`,
`--only-matching`, `-l`, `--count` and `-A/-B/-C` all break it.

File-selection flags are also applied to open buffers, in-process — ripgrep sees
the buffer pass as one nameless stdin stream, so its own `-g` and `-t` cannot
reach it, and without that a `--filter *.lua` search would quietly report
matches from a `.md` you have open.

The panel opens as soon as the search is triggered and says that it is
searching until the results replace it.

Files that are open in a buffer are searched from their current, unsaved text,
not from disk — their locations are marked with a distinct highlight.

### Mappings

| Key | Effect |
| --- | --- |
| `<CR>` | open the source of the line under the cursor, at that line and column |
| `K` | show the match under the cursor in a floating window: its full path, relative path, line number, whether it is already loaded in a buffer, and the source line as the panel rendered it |

The file opens in a regular window — the panel keeps its own, and is never
opened over. Set `keys.open` or `keys.hover` to a different key, or to `false`,
to change or drop either mapping.

The `file:line` column is capped at `path_width` display cells; a longer
location is cropped on the left, keeping the file name and line number visible.
`K` is how you see the whole path.

### Editing rules

The anchor in front of a line owns everything from that line down to the next
anchor, which makes the obvious edits mean the obvious thing:

- **change the line** → the source line is rewritten
- **delete the line** (`dd`) → that match is dropped: its source line is left
  exactly as it is
- **split it into several lines** → the source line is replaced by all of them
- **empty the panel** (`ggdG`) → nothing is changed at all

Deleting lines is how you narrow a result set down to the matches you actually
want to replace — it never removes anything from a file. The dropped line's
`file:line` disappears with it, so the locations left in the panel keep lining
up with the lines they belong to, and `u` brings both back.

A line whose source has moved since the search (an edit elsewhere, a reload) is
left untouched and reported as skipped. After a write the panel re-renders with
the applied text and corrected line numbers.

## Configuration

```lua
require("greplace").setup({
  height     = 15,    -- height of the result split
  limit      = 10000, -- maximum matches collected per search; a search that
                      -- hits it says so in the winbar
  winbar     = true,  -- show the panel's counts in a winbar
  path_width = 60,    -- greatest width of the `file:line` column, in cells
  keys = {
    open  = "<CR>", -- open the source of the line under the cursor
    hover = "K",    -- show the full details of the match under the cursor
  },
})
```

## Highlight groups

| Group | Default | Meaning |
| --- | --- | --- |
| `GreplaceLocation` | `Directory` | `file:line` of an on-disk match |
| `GreplaceBufferLocation` | `Special` | `file:line` of a match in an open buffer |
| `GreplaceSeparator` | `Comment` | the `│` between location and text |
| `GreplaceMatch` | `Search` | the matched text itself |
| `GreplaceLimit` | `WarningMsg` | the winbar's "limit of N reached" note |

## Development

```bash
make test
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim); set
`NVIM_PLENARY_DIR` to reuse an existing clone.

## License

MIT
