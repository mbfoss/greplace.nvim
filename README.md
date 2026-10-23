# assets

Orphan branch holding the demo recordings linked from the README on `main`.
It shares no history with `main` and carries nothing but these files.

| File | Scene |
| --- | --- |
| `demos/01-replace.gif` | Search, edit the result list, and write the changes back |
| `demos/02-flags.gif` | Narrow the search with flags, then drop a result |
| `demos/03-selection.gif` | Search for the visual selection, and the `K` hover |
| `demos/04-diff.gif` | Preview the write with `:Greplace diff` |

Regenerate them from `main` with `scripts/record-demos.sh`, then commit the
GIFs from `demo/out/` here.
