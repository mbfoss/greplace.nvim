# greplace.nvim

> WORK IN PROGRESS

Project-wide search and replace by editing the grep results.

```
:Gsearch <query>
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

`setup()` is optional; the `:Gsearch` command registers itself, and nothing
under `lua/greplace/` is loaded until it is first run.

## Usage

| Command | Effect |
| --- | --- |
| `:Gsearch foo bar` | literal search for `foo bar` (smart-case) |
| `:Gsearch! ^fn\s+\w+` | the query is a regex |
| `:Gsearch` | with no query: re-run the last one, discarding unapplied edits |

Everything after `:Gsearch` is the query, verbatim — spaces, quotes and
backslashes included.

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
