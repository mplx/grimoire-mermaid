#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Refresh src/pluginkit.j from a Grimoire checkout: ../grimoire, or the one
# GRIMOIRE_SRC names. The copy is never edited here; a change belongs in
# Grimoire first.

set -eu

cd "$(dirname "$0")/.."
sibling=${GRIMOIRE_SRC:-../grimoire}
if [ ! -f "$sibling/src/pluginkit.j" ]; then
    echo "no Grimoire checkout at $sibling (set GRIMOIRE_SRC)" >&2
    exit 1
fi
if cmp -s "$sibling/src/pluginkit.j" src/pluginkit.j; then
    echo "src/pluginkit.j is current"
else
    cp "$sibling/src/pluginkit.j" src/pluginkit.j
    echo "src/pluginkit.j refreshed from $sibling"
fi
