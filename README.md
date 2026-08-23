# greplace.nvim

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

`setup()` is optional; the `:Gsearch` command registers itself.

## Usage

| Command | Effect |
| --- | --- |
| `:Gsearch foo bar` | literal search for `foo bar` (smart-case) |
| `:Gsearch! ^fn\s+\w+` | the query is a regex |
| `:Gsearch` | re-run the last query, discarding unapplied edits |

Files that are open in a buffer are searched from their current, unsaved text,
not from disk — their locations are marked with a distinct highlight.

### Editing rules

The anchor in front of a line owns everything from that line down to the next
anchor, which makes the obvious edits mean the obvious thing:

- **change the line** → the source line is rewritten
- **delete the line** (`dd`) → the source line is deleted
- **split it into several lines** → the source line is replaced by all of them

A line whose source has moved since the search (an edit elsewhere, a reload) is
left untouched and reported as skipped. After a write the panel re-renders with
the applied text and corrected line numbers.

## Configuration

```lua
require("greplace").setup({
  height = 15,   -- height of the result split
  limit  = 2000, -- maximum matches collected per search
})
```

## Highlight groups

| Group | Default | Meaning |
| --- | --- | --- |
| `GreplaceLocation` | `Directory` | `file:line` of an on-disk match |
| `GreplaceBufferLocation` | `Special` | `file:line` of a match in an open buffer |
| `GreplaceSeparator` | `Comment` | the `│` between location and text |
| `GreplaceMatch` | `Search` | the matched text itself |

## Development

```bash
make test
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim); set
`NVIM_PLENARY_DIR` to reuse an existing clone.

## License

MIT
