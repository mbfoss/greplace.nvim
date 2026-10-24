#!/usr/bin/env sh
# Record the README demos from data/demo/scenes/*.scene with nvim-demo.
#
#   scripts/record-demos.sh                         # every scene
#   scripts/record-demos.sh data/demo/scenes/01-*.scene  # just one
#
# Each scene writes its GIF and cast to data/demo/out/. Needs nvim, agg, pyte and
# ripgrep. nvim-demo (https://github.com/mbfoss/nvim-demo-generator) is used
# from ~/src when that checkout is there, and cloned into
# $XDG_CACHE_HOME/greplace.nvim when it is not. Set NVIM_DEMO to a checkout's
# bin/nvim-demo to use that instead.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/greplace.nvim

if [ -n "${NVIM_DEMO:-}" ]; then
    demo=$NVIM_DEMO
elif [ -x "${HOME}/src/nvim-demo-generator/bin/nvim-demo" ]; then
    demo=${HOME}/src/nvim-demo-generator/bin/nvim-demo
else
    tool=$cache/nvim-demo-generator
    demo=$tool/bin/nvim-demo
    if [ ! -x "$demo" ]; then
        mkdir -p "${tool%/*}"
        git clone --depth 1 \
            https://github.com/mbfoss/nvim-demo-generator "$tool"
    fi
fi

# Every take searches a fresh copy of data/demo/work, so a recording never sees the
# previous one's edits and the panel shows paths relative to the project root.
work=$cache/work
rm -rf "$work"
mkdir -p "$work"
cp -R "$root/data/demo/work/." "$work/"

mkdir -p "$root/data/demo/out"
if [ "$#" -eq 0 ]; then
    set -- "$root"/data/demo/scenes/*.scene
fi

for scene in "$@"; do
    printf '=== %s\n' "$(basename "$scene")"
    GREPLACE_DEMO_WORK=$work "$demo" record "$scene"
done
