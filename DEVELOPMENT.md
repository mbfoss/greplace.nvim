# Development

Notes for working on greplace.nvim. For what the plugin does and how to use
it, see [README.md](README.md).

## Layout

```
plugin/greplace.lua        commands (:Gsearch, :Greplace), loaded by Neovim
lua/greplace/
  init.lua                 setup, search flow, and the commands' implementations
  config.lua               user configuration and its defaults
  search.lua               runs ripgrep and collects matches
  rgflags.lua              :Gsearch flags: schema and their ripgrep meaning
  qflist.lua               :Greplace qf, matches from the quickfix list
  apply.lua                writes the edited panel back into buffers
  preview.lua              :Greplace diff, what a write would change
  health.lua               :checkhealth greplace
  panel.lua                the panel buffer: lifecycle, keymaps, public API
  panel/
    marks.lua              anchor and bounds extmarks, repair, undo/redo
    render.lua             drawing a result list or a status
    winbar.lua             the winbar's counts
  util.lua, util/          buffer/path helpers, process spawning, UI helpers
doc/greplace.txt           generated from README.md, do not edit by hand
tests/                     busted specs, run inside Neovim
scripts/gendoc.sh          regenerates doc/greplace.txt
```

## Running the tests

The specs run under [busted](https://lunarmodules.github.io/busted/) inside
Neovim, so they can use the `vim` API. busted must be installed for Lua 5.1,
the version Neovim embeds:

```sh
luarocks --lua-version=5.1 --local install busted
```

Then:

```sh
make test
make test BUSTED_ARGS="--filter=reloaded"     # only specs matching a name
make test BUSTED_ARGS="-o gtest"              # another output handler
```

`make test` never installs anything itself; it fails with instructions if
busted or `nvim` is missing. Set `NVIM` to test against a different binary.

`tests/edit_spec.lua` drives a second, embedded Neovim with typed input. The
panel repairs edits from `vim.schedule` callbacks, which need a real main loop
and real keystrokes, and a spec run directly under busted has neither. Use its
`Child` helper for anything that depends on how the panel reacts to an edit.

## Documentation

`doc/greplace.txt` is generated from `README.md` with panvimdoc, so change the
README and regenerate:

```sh
scripts/gendoc.sh           # rewrite doc/greplace.txt and doc/tags
scripts/gendoc.sh --check   # exit 1 when the help file is out of date
```

It needs `pandoc`. Markdown that has no place in a help file goes between
`panvimdoc-ignore` markers; the header of the script explains the rest.

## How the panel works

The panel is one scratch buffer, `greplace://greplace-matches`, with one line
per match. It is edited as ordinary text, so almost everything in
`lua/greplace/panel/` is about keeping that promise while the user is free to
join, split, delete, put and undo lines.

Read the design comment at the top of [`panel/marks.lua`](lua/greplace/panel/marks.lua)
before changing anything there. The short version:

- Each match has an **anchor** extmark, which draws the `file:line` location
  and is the record of which match a row belongs to, and a **bounds** extmark
  spanning the match's text. A change that broke one line per match can be
  read off those marks alone and repaired without remembering anything.
- Repairs are joined to the change that caused them (`undojoin`), so every
  undo state holds one line per match and undo and redo need no help of their
  own. They only lay the marks out again from the listing.
- Writing (`:w`) reads the buffer back as one region per anchor
  (`panel.regions`); `apply.lua` turns regions into buffer edits.

### Ownership and state

- `panel.lua` owns the per-buffer state (`_state`) and the pending-pass
  callbacks (`_drop_pending`). Nothing else keeps a table of panels.
- The other panel modules never look a state up by buffer number. They are
  handed the `greplace.PanelState` they work on as an argument.
- Each extmark namespace is created by the module that owns it and exported
  from there (`marks.ns`, `draw.ns_hl`).
- The types (`greplace.Entry`, `greplace.PanelState`, `greplace.Region`) are
  declared in `panel.lua`; `greplace.Stats` is declared in `panel/winbar.lua`.

### Things that are easy to break

- Changing the text of a match with `nvim_buf_set_lines` covers an anchor's
  span in full and invalidates it, which reads as the match having been
  deleted. Use `nvim_buf_set_text` on ranges that stay clear of the span, as
  `join_row`, `split_row` and `delete_row` do.
- Every state in the undo tree must be one the panel put in shape when it was
  made. A new kind of edit needs to be covered by `repair` or it will leave the
  undo history holding states that need repair of their own.
- Renders clear the undo history on purpose (`set_lines_no_undo`), so `u`
  cannot walk back into a previous search.
- The `≡` marker records where a line came from when the search ran, a buffer
  or the disk. It is not kept in step with which files are open afterwards.

## Conventions

- Comments explain why, and are kept close to the code they describe. Match the
  density of the surrounding code.
- Public functions and shared types carry LuaLS annotations (`---@param`,
  `---@return`, `---@class`).
- Commit messages follow `type: subject` (`fix:`, `feat:`, `refactor:`,
  `docs:`), lower case, in the imperative.
