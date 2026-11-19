#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Build examples/book end to end and check every edition: the site links SVGs
# that are there, the EPUB carries them and parses as XML, and the PDF holds the
# PNGs. A second build at another --jobs has to give the same bytes.
#
# Needs a Grimoire with the `files` feature (0.5.0 or later), a renderer
# (merman-cli, or mmdr with RENDERER=mmdr), unzip and python3:
#
#   GRIMOIRE="$PWD/../grimoire/bin/grimoire" scripts/check-example.sh
#
# GRIMOIRE is run from a copy of the book in a temp directory, so it has to be
# a command on PATH or an absolute path.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
GRIMOIRE=${GRIMOIRE:-grimoire}
RENDERER=${RENDERER:-merman}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/examples/book" "$work/book"
cd "$work/book"
# The launcher by absolute path, since the copy is not beside the repository.
sed -i "s|^command = .*|command = \"$root/bin/grimoire-mermaid\"\nrenderer = \"$RENDERER\"|" grimoire.toml

fail() { echo "FAIL: $*" >&2; exit 1; }

"$GRIMOIRE" build --quiet --jobs 1 --out site
"$GRIMOIRE" build --quiet --jobs 4 --out again
diff -r site again >/dev/null || fail "--jobs 1 and --jobs 4 differ"
echo "ok  same bytes at --jobs 1 and 4"

svgs=$(ls site/_generated/mermaid/*.svg | wc -l)
pngs=$(ls site/_generated/mermaid/*.png | wc -l)
[ "$svgs" -eq 3 ] && [ "$pngs" -eq 3 ] || fail "expected 3 SVGs and 3 PNGs, got $svgs and $pngs"
grep -q 'src="_generated/mermaid/[0-9a-f]*\.svg" alt="From Markdown to a book"' site/index.html \
    || fail "index.html does not show the flowchart"
[ "$(grep -o 'src="\.\./_generated/mermaid/[0-9a-f]*\.svg"' site/guide/build.html | wc -l)" -eq 2 ] \
    || fail "guide/build.html does not show two diagrams"
grep -q 'A --&gt; B' site/index.html || fail "the fenced example was drawn"
echo "ok  site"

mkdir epub
(cd epub && unzip -q ../site/diagrams.epub)
[ "$(ls epub/OEBPS/_generated-mermaid-*.svg | wc -l)" -eq 3 ] || fail "the EPUB does not carry 3 SVGs"
python3 -I - "$PWD/epub" <<'PY' || fail "the EPUB holds a file that is not XML"
import glob, sys, xml.etree.ElementTree as ET
for f in glob.glob(sys.argv[1] + "/**/*", recursive=True):
    if f.endswith((".xhtml", ".svg", ".opf", ".xml")):
        ET.parse(f)
PY
echo "ok  epub"

python3 -I - site/book.pdf <<'PY' || fail "the PDF does not draw 3 pictures"
import re, sys
data = open(sys.argv[1], "rb").read()
sizes = set(re.findall(rb"/Width (\d+)\s*/Height (\d+)", data))
sys.exit(0 if len(sizes) >= 3 else 1)
PY
echo "ok  pdf"
