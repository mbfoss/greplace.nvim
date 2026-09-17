#!/usr/bin/env sh
# Generate doc/<project_name>.txt from README.md with panvimdoc.
#
#   scripts/gendoc.sh           # rewrite doc/<project_name>.txt and doc/tags
#   scripts/gendoc.sh --check   # exit 1 when the help file is out of date
#
# Markdown that has no place in a help file (badges, screenshots, links to
# files on the forge) goes between panvimdoc-ignore markers:
#
#   <!-- panvimdoc-ignore-start -->
#   ![A screenshot](https://...)
#   <!-- panvimdoc-ignore-end -->
#
# and its help-file counterpart, invisible where markdown is rendered, goes in a
# vimdoc-only comment, uncommented here on the way to panvimdoc:
#
#   <!-- vimdoc-only
#   See |greplace-configuration| for the full option list.
#   -->
#
# Needs pandoc (brew install pandoc). panvimdoc itself is fetched on first run
# and cached, pinned to the commit in PANVIMDOC_COMMIT below -- a tag can be
# moved, a commit cannot -- so the help file is reproducible. Point
# PANVIMDOC_DIR at a checkout of your own to use that instead. nvim is only
# used to refresh doc/tags, and is optional.

set -eu

PANVIMDOC_COMMIT=662fb20304d20c539fb48a0bda628f5165507de7 # v4.0.1
PANVIMDOC_URL=https://github.com/kdheepak/panvimdoc.git

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=greplace
description="Search and replace in multiple files"
vimversion="Neovim >= 0.10"

out="$root/doc/$project.txt"
work="${TMPDIR:-/tmp}/$project-doc.$$"
trap 'rm -rf "$work"' EXIT INT TERM

die() {
    echo "gendoc: $*" >&2
    exit 1
}

command -v pandoc >/dev/null || die "pandoc not found (brew install pandoc)"

# Resolve panvimdoc: either a caller-supplied checkout, or the pinned commit in
# the user's cache. A plain clone cannot name a commit, so fetch that object and
# check it out directly, then confirm a reused cache is still at that commit.
if [ -n "${PANVIMDOC_DIR:-}" ]; then
    panvimdoc=$PANVIMDOC_DIR
    [ -f "$panvimdoc/panvimdoc.sh" ] || die "no panvimdoc.sh in PANVIMDOC_DIR=$panvimdoc"
else
    panvimdoc="${XDG_CACHE_HOME:-$HOME/.cache}/panvimdoc-$PANVIMDOC_COMMIT"
    if [ ! -f "$panvimdoc/panvimdoc.sh" ]; then
        echo "fetching panvimdoc $PANVIMDOC_COMMIT into $panvimdoc"
        rm -rf "$panvimdoc"
        mkdir -p "$panvimdoc"
        git -C "$panvimdoc" init --quiet
        git -C "$panvimdoc" fetch --quiet --depth 1 "$PANVIMDOC_URL" "$PANVIMDOC_COMMIT"
        git -c advice.detachedHead=false -C "$panvimdoc" checkout --quiet FETCH_HEAD
    fi
    have=$(git -C "$panvimdoc" rev-parse HEAD)
    [ "$have" = "$PANVIMDOC_COMMIT" ] ||
        die "$panvimdoc is at $have, expected $PANVIMDOC_COMMIT; remove it and re-run"
fi

# Help tags come from a hidden comment at the end of a section heading. The
# project name is prefixed automatically, so this yields *<project_name>-sources*:
#
#   ## Custom sources <!-- tag: sources -->
#
# Without one, panvimdoc derives the tag from the heading text. Collect
# "derived-tag<TAB>wanted-tag" pairs and strip the comments from the copy
# panvimdoc reads; the derived tags are rewritten in the output below.
mkdir -p "$work/doc"
awk -v project="$project" -v md="$work/README.md" '
    # Help-file-only text, invisible to a markdown renderer.
    /^[ \t]*<!--[ \t]*vimdoc-only[ \t]*$/ { vimdoc = 1; next }
    vimdoc && /^[ \t]*-->[ \t]*$/         { vimdoc = 0; next }

    /^##+[ \t].*<!--[ \t]*tag:[^>]*-->[ \t]*$/ {
        tag = $0
        sub(/^.*<!--[ \t]*tag:[ \t]*/, "", tag)
        sub(/[ \t]*-->[ \t]*$/, "", tag)
        sub(/[ \t]*<!--[ \t]*tag:[^>]*-->[ \t]*$/, "")
        if (tag !~ /^[A-Za-z0-9_-]+$/) {
            print "gendoc: bad help tag \"" tag "\" on " $0 > "/dev/stderr"
            exit 1
        }
        heading = $0
        sub(/^#+[ \t]*/, "", heading)
        # panvimdoc derives the tag from the rendered heading, so drop the
        # inline markers pandoc consumes on the way there.
        gsub(/[`*_]/, "", heading)
        gsub(/[ \t]+/, "-", heading)
        print project "-" tolower(heading) "\t" project "-" tag
    }
    { print > md }
' "$root/README.md" > "$work/tagmap"

# panvimdoc writes to doc/<project>.txt relative to the working directory, so
# run it in a scratch tree and compare from there.
(
    cd "$work"
    sh "$panvimdoc/panvimdoc.sh" \
        --project-name "$project" \
        --input-file "$work/README.md" \
        --vim-version "$vimversion" \
        --description "$description" \
        --toc true \
        --dedup-subheadings false \
        --shift-heading-level-by -1 \
        --treesitter true
) >/dev/null

# Swap in the tags declared in README.md, keeping the trailing tag right-aligned
# and the |links| to it in sync.
awk '
    FILENAME == ARGV[1] {   # NR == FNR would swallow file 2 on an empty tagmap
        i = index($0, "\t")
        map[substr($0, 1, i - 1)] = substr($0, i + 1)
        next
    }
    {
        line = $0
        for (k in map) {
            gsub("\\*" k "\\*", "*" map[k] "*", line)
            gsub("\\|" k "\\|", "|" map[k] "|", line)
        }
        if (line != $0 && match(line, /[*|][^ *|]+[*|]$/)) {
            token = substr(line, RSTART)
            head = substr(line, 1, RSTART - 1)
            sub(/[ \t]+$/, "", head)
            pad = length($0) - length(head) - length(token)
            if (pad < 1) pad = 1
            line = head sprintf("%" pad "s", "") token
        }
        print line
    }
' "$work/tagmap" "$work/doc/$project.txt" > "$work/$project.txt.tags"

# panvimdoc heads the file with a *<project>.txt* tag. Nothing links to a help
# file by its filename, so make it the plain *<project>* the rest of the tags
# are named after, keeping the description right-aligned where it was.
awk -v project="$project" '
    NR == 1 && index($0, "*" project ".txt*") == 1 {
        tag  = "*" project "*"
        desc = substr($0, length(project) + 8)
        sub(/^[ \t]+/, "", desc)
        pad = length($0) - length(tag) - length(desc)
        if (pad < 1) pad = 1
        $0 = tag sprintf("%" pad "s", "") desc
    }
    { print }
' "$work/$project.txt.tags" > "$work/$project.txt"

if [ "${1:-}" = "--check" ]; then
    cmp -s "$work/$project.txt" "$out" && {
        echo "$out is up to date"
        exit 0
    }
    echo "$out is out of date; run: scripts/gendoc.sh" >&2
    [ "${2:-}" = "--diff" ] && diff -u "$out" "$work/$project.txt" || true
    exit 1
fi

cp "$work/$project.txt" "$out"
echo "wrote $out"

command -v nvim >/dev/null || {
    echo "nvim not found; run :helptags doc to refresh tags" >&2
    exit 0
}
nvim --headless -c "helptags $root/doc" -c qa >/dev/null 2>&1 && [ -f "$root/doc/tags" ] ||
    die "helptags failed; run :helptags doc by hand"
echo "wrote $root/doc/tags"
