#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Formatting, lint and the unit tests: what CI runs.
#
# The tests run from the repository root, because they reach the fake renderer
# at tests/fake-renderer. `JENNIFER` picks the interpreter.

set -eu

cd "$(dirname "$0")/.."
JENNIFER=${JENNIFER:-jennifer}

# src/pluginkit.j is a copy of Grimoire's kit. When a Grimoire checkout is
# beside this one (or at GRIMOIRE_SRC), say if the copy has fallen behind it;
# scripts/sync-kit.sh refreshes it. A warning, not a failure: CI has no checkout.
sibling=${GRIMOIRE_SRC:-../grimoire}
if [ -f "$sibling/src/pluginkit.j" ] && ! cmp -s "$sibling/src/pluginkit.j" src/pluginkit.j; then
    echo "note: src/pluginkit.j differs from $sibling/src/pluginkit.j (scripts/sync-kit.sh)" >&2
fi
SOURCES="src/mermaid.j src/mermaid_test.j bin/grimoire-mermaid"

unformatted=$("$JENNIFER" fmt -l $SOURCES)
if [ -n "$unformatted" ]; then
    printf 'not formatted (run `jennifer fmt -w`):\n%s\n' "$unformatted" >&2
    exit 1
fi
echo "ok  format"

# lint exits 0 even with findings, so the findings themselves are the gate.
findings=$("$JENNIFER" lint $SOURCES 2>&1)
if [ -n "$findings" ]; then
    printf '%s\n' "$findings" >&2
    exit 1
fi
echo "ok  lint"

out=$("$JENNIFER" test src/mermaid_test.j 2>&1) || true
summary=$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed' || true)
case "$summary" in
    *" 0 failed"*) echo "ok  tests: $summary" ;;
    *) printf '%s\n' "$out" | grep -v '^PASS' >&2; exit 1 ;;
esac
